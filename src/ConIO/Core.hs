{-# LANGUAGE TypeFamilies #-}

module ConIO.Core
  ( -- ** Concurrent IO
    ConIO,
    runConIO,
    runConIOCancel,

    -- ** Tasks
    Task,
    launch,
    AsyncThread (..),
    cancelAll,

    -- ** Manage scopes
    ConScope,
    withConScope,
    useConScope,
    UnsafeConScope,
    toUnsafeConScope,
    fromUnsafeConScope,

    -- ** Exceptions
    ConIOException (..),
    ConIOKillThread (..),

    -- ** Internal
    Task (..),
  )
where

import ConIO.MonadSTM
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (void)
import Control.Monad.Fix
import Control.Monad.IO.Class
import Control.Monad.Trans.Reader
import Data.Foldable (traverse_)
import Data.IORef
import Data.Map qualified as M
import Data.Maybe (fromMaybe)
import Data.Set qualified as S

-- | The 'ConIO' environment keeps track of child processes and whether its enabled.
data ConEnv = ConEnv
  { enabled :: MVar Bool,
    children :: IORef (M.Map ThreadId (IO ())),
    threadId :: ThreadId
  }

-- | Create an enabled environment with no children
makeConEnv :: IO ConEnv
makeConEnv = ConEnv <$> newMVar True <*> newIORef M.empty <*> myThreadId

-- | 'ConIO' stands for concurrent IO. 'ConIO' works like normal 'IO',
--  but you can also fork off threads without worry.
-- Tasks launched within  'ConIO' will __never outlive__ the 'ConIO' scope.
-- Before 'ConIO' ends, it will __wait for all threads to finish or cancel them__.
-- Additionally, exceptions between parent and children are propagated per default,
-- completely shutting down all processes when an exception happens anywhere.
--
-- You do not have to worry about:
--
-- - Zombie processes, since a thread can never outlive its parent scope.
-- - Dead processes, since exceptions will propagate to the parent thread.
newtype ConIO a = ConIO (ReaderT ConEnv IO a) deriving newtype (Functor, Applicative, Monad, MonadIO, MonadFail, MonadFix, MonadSTM)

getEnv :: ConIO (ConEnv)
getEnv = ConIO ask

-- | Opens up a concurrent scope by running 'ConIO'. No threads launched within 'ConIO' outlive this scope, since it waits for them to finish.
runConIO :: (MonadIO m) => ConIO a -> m a
runConIO (ConIO r) = liftIO $ do
  env <- makeConEnv
  catch
    ( do
        a <- runReaderT r env
        readIORef env.children >>= sequence_
        pure a
    )
    (\(e :: SomeException) -> killConIO env >> throwIO e)

-- | Opens up a concurrent scope by running 'ConIO. Cancels all Tasks before returning.
runConIOCancel :: (MonadIO m) => ConIO a -> m a
runConIOCancel (ConIO r) = liftIO $ do
  env <- makeConEnv
  catch
    ( do
        a <- runReaderT r env
        killConIO env
        pure a
    )
    (\(e :: SomeException) -> killConIO env >> throwIO e)

-- | 'launch' is the main way to spin up new threads.
-- It will execute the given action in another thread and returns a 'Task'.
launch :: IO a -> ConIO (Task a)
launch action = do
  env <- getEnv
  maybeA <- liftIO $ withLock env $ do
    tvar <- newTVarIO StillRunning
    tId <- mask $ \restore -> forkIO $ do
      couldBeA <- try $ restore action
      case couldBeA of
        Right a -> atomically $ writeTVar tvar (Success a)
        Left err -> do
          case fromException @ConIOKillThread err of
            Just _conIOKillTask -> do
              atomically $ writeTVar tvar (Failure (toException ConIOKillThread))
            Nothing -> do
              atomically $ writeTVar tvar (Failure (toException err))
              throwTo env.threadId (ConIOTaskException err)
    let readValue = do
          value <- readTVar tvar
          case value of
            StillRunning -> retry
            Success a -> pure a
            Failure err -> throwSTM err
    let isDone = do
          value <- readTVar tvar
          case value of
            StillRunning -> retry
            Success _a -> pure ()
            Failure _err -> pure ()
    liftIO $ atomicModifyIORef' env.children $ \children -> (M.insert tId (atomically isDone) children, ())
    pure $
      Task
        { payload = readValue,
          threadIds = S.singleton tId
        }

  -- It's better to not throw an exception immediately.
  -- If you throw the ConIODisabled exception immediately, you introduce non-deterministic exception-throwing
  -- Depending on whether cancelAll or launch is executed first, it would throw an exception or not.
  -- If you only throw when reading the payload, then this is similar behavior to launching, then cancelling, then reading.
  pure $ fromMaybe (Task {payload = throwSTM ConIODisabled, threadIds = S.empty}) maybeA

-- | A 'Task' represents a thread which is producing some `a`. You can 'wait' for Tasks or 'cancel' them.
--
-- 'fmap' on a 'Task' will run the function in the thread waiting for the result, not the task thread.
data Task a = Task
  { payload :: STM a,
    threadIds :: S.Set ThreadId
  }

instance Functor Task where
  fmap f task = task {payload = f <$> task.payload}

conIOkillTask :: ThreadId -> IO ()
conIOkillTask tId = throwTo tId ConIOKillThread

-- | Aquire the 'enabled' lock and do something only if the 'ConEnv' is still enabled.
withLock :: ConEnv -> IO a -> IO (Maybe a)
withLock env action = do
  mEnabled <- tryReadMVar env.enabled
  if mEnabled == Just False
    then pure Nothing
    else
      bracket
        (takeMVar env.enabled)
        (putMVar env.enabled)
        ( \enabled ->
            if enabled
              then Just <$> action
              else pure Nothing
        )

-- | Kill the 'ConIO' scope and disable the environment. Will wait until all children threads are dead.
killConIO :: ConEnv -> IO ()
killConIO env = void $ try @SomeException $ do
  modifyMVarMasked_ env.enabled $ \enabled ->
    if enabled
      then do
        void $ try @ConIOException $ do
          children <- readIORef env.children
          liftIO $ traverse_ conIOkillTask (M.keys children)
          liftIO $ sequence_ children
        pure False
      else pure False

-- | Cancel the whole scope, killing all spawned threads and disabling the 'ConIO' scope.
-- You cannot 'launch' any more threads from a disabled 'ConIO' scope.
cancelAll :: ConIO ()
cancelAll = do
  env <- getEnv
  _ <- liftIO $ void $ killConIO env
  pure ()

-- | A 'ConIO' scope which can be passed around
newtype ConScope s = ConScope ConEnv

-- | Get the 'ConIO' scope and use it in an internal computation.
-- The `forall s.` prevents incorrect usage of the scope.
withConScope :: (forall s. ConScope s -> IO a) -> ConIO a
withConScope f = do
  env <- ConIO ask
  a <- liftIO $ f (ConScope env)
  pure a

-- | Use the 'ConScope' to run a 'ConIO' in the original scope.
useConScope :: ConScope s -> ConIO a -> IO a
useConScope (ConScope env) (ConIO r) = runReaderT r env

-- | An 'UnsafeConScope' has no forall quantifier,
-- making it possible for scopes to escape their originating 'ConIO'.
-- Use this only if you know what you are doing.
newtype UnsafeConScope = UnsafeConScope ConEnv

toUnsafeConScope :: ConScope s -> UnsafeConScope
toUnsafeConScope (ConScope env) = UnsafeConScope env

fromUnsafeConScope :: UnsafeConScope -> (forall s. ConScope s -> a) -> a
fromUnsafeConScope (UnsafeConScope env) f = f (ConScope env)

-- | 'ConIOException' is used for all exceptions related to threads created by 'launch'.
data ConIOException
  = -- | Happens when you try to 'launch' from within a disabled environment
    ConIODisabled
  | -- | Happens when a child thread throws an exception
    ConIOTaskException SomeException
  deriving (Show)

instance Exception ConIOException

-- | The 'ConIOKillThread' exception is used internally to kill threads without bringing down the whole 'ConIO' scope.
--
-- Do not catch this exception, unless you know what you are doing.
-- Keep in mind to rethrow 'AsyncException' if you catch 'SomeException'!
--
-- A normal SIGKILL triggered by the external system will shutdown the whole 'ConIO' scope.
data ConIOKillThread = ConIOKillThread deriving (Show)

instance Exception ConIOKillThread

-- | The state of 'Task'.
data Result a = StillRunning | Success a | Failure SomeException

-- | A typeclass for all async workers which you can wait for.
class AsyncThread t where
  type Payload t

  -- | Wait for an async worker and return its payload.
  wait :: (MonadSTM m) => t -> m (Payload t)

  -- | Cancel an async worder, killing all threads which are part of it.
  -- 'cancel' returns immediately and does not wait for the canceled threads to die.
  --
  -- If you want to wait for threads to die, you need to start them in a separate scope.
  cancel :: (MonadIO m) => t -> m ()

instance AsyncThread (Task a) where
  type Payload (Task a) = a
  wait (Task payload _) = liftSTM payload
  cancel (Task _ threadIds) = liftIO $ traverse_ conIOkillTask threadIds
