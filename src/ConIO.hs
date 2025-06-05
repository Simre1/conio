{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE RecursiveDo #-}

module ConIO where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.Fix (MonadFix)
import Control.Monad.IO.Class
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Class
import Control.Monad.Trans.Reader
import Data.Foldable
import Data.Functor (($>))
import Data.Functor.Product
import Data.IORef
import Data.Map qualified as M
import Data.Maybe
import Data.Set qualified as S

-- | The 'ConIO' environment keeps track of child processes and whether its enabled.
data ConEnv = ConEnv
  { enabled :: MVar Bool,
    children :: IORef (M.Map ThreadId (IO ()))
  }

-- | Created an enabled environment with no children
makeConEnv :: IO ConEnv
makeConEnv = ConEnv <$> newMVar True <*> newIORef M.empty

-- | 'ConIO' stands for concurrent IO. 'ConIO' works like normal 'IO',
--  but you can also fork off threads without worry.
-- Threads launched from which 'ConIO' will __never outlive__ the 'ConIO' scope.
-- Before 'ConIO' ends, it will wait for all threads to finish.
-- Additionally, exceptions between parent and children are propagated per default,
-- completely shutting down all processes when an exception happens anywhere.
--
-- You do not have to worry about:
-- - Zombie processes, since a thread can never outlive its parent scope.
-- - Dead processes, since exceptions will propagate to the parent thread.
newtype ConIO a = ConIO (ReaderT ConEnv IO a) deriving newtype (Functor, Applicative, Monad, MonadIO, MonadFail, MonadFix)

getEnv :: ConIO (ConEnv)
getEnv = ConIO ask

-- | A 'Task' represents a thread which is producing some a. You can 'wait' for tasks or 'cancel' them.
data Task a = Task
  { payload :: STM a,
    threadIds :: S.Set ThreadId
  }

instance Functor Task where
  fmap f task = task {payload = f <$> task.payload}

instance Applicative Task where
  pure a =
    Task
      { payload = pure a,
        threadIds = S.empty
      }
  (Task payloadF threadIdsF) <*> (Task payloadA threadIdsA) =
    Task
      { payload = payloadF <*> payloadA,
        threadIds = threadIdsF <> threadIdsA
      }

data ConIOKillThread = ConIOKillThread deriving (Show)

instance Exception ConIOKillThread

hubKill :: ThreadId -> IO ()
hubKill tId = throwTo tId ConIOKillThread

cancel :: (MonadIO m) => Task a -> m ()
cancel (Task payload tIds) = liftIO $ do
  liftIO $ traverse_ hubKill tIds
  pure ()

cancelMany :: (Traversable t, MonadIO m) => t (Task a) -> m ()
cancelMany tasks = liftIO $ do
  liftIO $ forM_ tasks $ \task -> traverse_ hubKill task.threadIds
  pure ()

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

concurrently :: (MonadIO m) => ConIO a -> m a
concurrently = runConIO

launch :: IO a -> ConIO (Task a)
launch action = do
  env <- getEnv
  myId <- liftIO $ myThreadId
  maybeA <- liftIO $ withLock env $ do
    tvar <- newTVarIO StillWaiting
    tId <- mask $ \restore -> forkIO $ do
      couldBeA <- try $ restore action
      case couldBeA of
        Right a -> atomically $ writeTVar tvar (Success a)
        Left err -> do
          case fromException @ConIOKillThread err of
            Just _hubKillThread -> do
              atomically $ writeTVar tvar (Failure (toException ConIOKillThread))
            Nothing -> do
              atomically $ writeTVar tvar (Failure (toException $ ConIOTaskException err))
              throwTo myId (ConIOTaskException err)
    let readValue = do
          value <- readTVar tvar
          case value of
            StillWaiting -> retry
            Success a -> pure a
            Failure err -> throwSTM err
    let isDone = do
          value <- readTVar tvar
          case value of
            StillWaiting -> retry
            Success a -> pure ()
            Failure err -> pure ()
    liftIO $ atomicModifyIORef' env.children $ \children -> (M.insert tId (atomically isDone) children, ())
    pure $
      Task
        { payload = readValue,
          threadIds = S.singleton tId
        }
  pure $ fromMaybe (Task {payload = throwSTM ConIODisabled, threadIds = S.empty}) maybeA

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

killConIO :: ConEnv -> IO ()
killConIO env = void $ try @SomeException $ do
  modifyMVarMasked_ env.enabled $ \enabled ->
    if enabled
      then do
        killAndWait env
        pure False
      else pure False

killAndWait :: ConEnv -> IO ()
killAndWait env = void $ try @ConIOException $ do
  children <- readIORef env.children
  liftIO $ traverse_ hubKill (M.keys children)
  _ <- liftIO $ sequence_ children
  pure ()

waitTask :: (MonadSTM m) => Task a -> m a
waitTask (Task payload _) = liftSTM payload

cancelAll :: ConIO ()
cancelAll = do
  env <- getEnv
  _ <- liftIO $ void $ killConIO env
  pure ()

newtype ConScope s = ConScope ConEnv

withConScope :: (forall s. ConScope s -> IO a) -> ConIO a
withConScope f = do
  env <- ConIO ask
  a <- liftIO $ f (ConScope env)
  pure a

useConScope :: ConScope s -> ConIO a -> IO a
useConScope (ConScope env) (ConIO r) = runReaderT r env

instance Exception ConIOException

data ConIOException = ConIOCancelled | ConIODisabled | ConIOTaskException SomeException deriving (Show)

data Result a = StillWaiting | Success a | Failure SomeException

raceTwo :: IO a -> IO a -> ConIO (Task a)
raceTwo action1 action2 = mdo
  result <- liftIO newEmptyTMVarIO
  task1 <- launch $ do
    value1 <- action1
    wasPut <- atomically $ tryPutTMVar result value1
    when wasPut $ cancel task2
  task2 <- launch $ do
    value2 <- action2
    wasPut <- atomically $ tryPutTMVar result value2
    when wasPut $ cancel task1
  pure $
    Task
      { payload = takeTMVar result,
        threadIds = task1.threadIds <> task2.threadIds
      }

raceMany :: (Traversable t) => t (IO a) -> ConIO (Task a)
raceMany actions = do
  raceResult <- liftIO newEmptyTMVarIO
  tasksMVar <- liftIO $ newEmptyMVar
  tasks <- withConScope $ \scope -> forM actions $ \action -> do
    task <- useConScope scope $ launch $ do
      result <- action
      wasPut <- atomically $ tryPutTMVar raceResult result
      when wasPut $ do
        tasks <- readMVar tasksMVar
        useConScope scope $ void $ launch $ cancelMany tasks
    pure task
  liftIO $ putMVar tasksMVar tasks
  pure $
    Task
      { payload = readTMVar raceResult,
        threadIds = foldMap (.threadIds) tasks
      }

timeout :: Duration -> IO a -> ConIO (Maybe a)
timeout duration action = do
  t <- raceTwo (Just <$> action) (threadDelay maxWaitTime >> pure Nothing)
  waitTask t
  where
    maxWaitTime = fromIntegral $ durationToMicros duration

raceTwoTasks :: Task a -> Task a -> ConIO (Task a)
raceTwoTasks task1 task2 = mdo
  result <- liftIO newEmptyMVar
  checkTask1 <- launch $ do
    value1 <- waitTask task1
    wasPut <- tryPutMVar result value1
    when wasPut $ cancel task2 >> cancel checkTask2
  checkTask2 <- launch $ do
    value2 <- waitTask task2
    wasPut <- tryPutMVar result value2
    when wasPut $ cancel task1 >> cancel checkTask1
  task <- launch $ takeMVar result
  pure task

raceManyTasks :: (Traversable t) => t (Task a) -> ConIO (Task a)
raceManyTasks tasks = do
  raceResult <- liftIO newEmptyMVar
  checkTasks <- forM tasks $ \task -> do
    checkTask <- launch $ do
      result <- waitTask task
      tryPutMVar raceResult result
    pure checkTask
  task <- launch $ do
    a <- takeMVar raceResult
    cancelMany $ Pair ((True <$) <$> tasks) checkTasks
    pure a
  pure task

andThen :: Task a -> (a -> IO b) -> ConIO (Task b)
andThen taskA f = launch $ waitTask taskA >>= f

data Duration = Milliseconds Word deriving (Show, Eq, Ord)

durationToMicros :: Duration -> Word
durationToMicros (Milliseconds w) = w * 1000

timeoutTask :: Duration -> Task a -> ConIO (Task (Maybe a))
timeoutTask duration task = do
  timer <- launch (threadDelay maxWaitTime >> pure Nothing)
  raceTwoTasks (Just <$> task) timer
  where
    maxWaitTime = fromIntegral $ durationToMicros duration

type Thread = Task ()

newtype Promise a = Promise (STM a) deriving (Functor, Applicative, Monad)

waitPromise :: Promise a -> STM a
waitPromise (Promise stm) = stm

-- MonadSTM class

class (Monad m) => MonadSTM m where
  liftSTM :: STM a -> m a
  liftSTM_IO :: STM a -> IO a -> m a
  liftSTM_IO stm _ = liftSTM stm

instance MonadSTM STM where
  liftSTM = id

instance MonadSTM IO where
  liftSTM = atomically
  liftSTM_IO _ io = io

instance MonadSTM ConIO where
  liftSTM = liftIO . liftSTM
  liftSTM_IO _ io = liftIO io

instance (MonadSTM m, MonadTrans t) => MonadSTM (t m) where
  liftSTM = lift . liftSTM
  liftSTM_IO stm io = lift $ liftSTM_IO stm io

-- Utilities

waitForever :: (MonadIO m) => m a
waitForever = liftIO $ forever (threadDelay maxBound)

newtype Gate = Gate (TMVar ())

newGate :: (MonadSTM m) => m Gate
newGate = Gate <$> liftSTM_IO newEmptyTMVar newEmptyTMVarIO

waitGate :: (MonadSTM m) => Gate -> m ()
waitGate (Gate mVar) = liftSTM $ readTMVar mVar

openGate :: (MonadSTM m) => Gate -> m ()
openGate (Gate mVar) = liftSTM $ void $ tryPutTMVar mVar ()

newtype Switch = Switch (TVar Bool)

waitToggle :: (MonadSTM m) => Switch -> STM a -> m a
waitToggle (Switch tVar) m = liftSTM $ do
  a <- readTVar tVar
  if a
    then m
    else retry

setSwitch :: (MonadSTM m) => Switch -> m ()
setSwitch (Switch tVar) = liftSTM $ writeTVar tVar True

unsetSwitch :: (MonadSTM m) => Switch -> m ()
unsetSwitch (Switch tVar) = liftSTM $ writeTVar tVar False

toggleSwitch :: (MonadSTM m) => Switch -> m ()
toggleSwitch (Switch tVar) = liftSTM $ do
  state <- readTVar tVar
  if state
    then writeTVar tVar False
    else writeTVar tVar True

newtype Variable a = Variable (TVar a)

waitVariable :: (MonadIO m) => (a -> Bool) -> Variable a -> m a
waitVariable myCheck (Variable tVar) = liftIO $ atomically $ do
  a <- readTVar tVar
  if (myCheck a)
    then pure a
    else retry

newVariable :: (MonadSTM m) => a -> m (Variable a)
newVariable a = Variable <$> liftSTM_IO (newTVar a) (newTVarIO a)

writeVariable :: (MonadSTM m) => Variable a -> a -> m ()
writeVariable (Variable tVar) a = liftSTM $ writeTVar tVar a

getVariable :: (MonadSTM m) => Variable a -> m a
getVariable (Variable tVar) = liftSTM $ readTVar tVar

newtype Counter = Counter (TVar Int)

newCounter :: (MonadSTM m) => m Counter
newCounter = Counter <$> liftSTM_IO (newTVar 0) (newTVarIO 0)

getCounter :: (MonadSTM m) => Counter -> m Int
getCounter (Counter tVar) = liftSTM $ readTVar tVar

setCounter :: (MonadSTM m) => Counter -> Int -> m ()
setCounter (Counter tVar) i = liftSTM $ writeTVar tVar i

incrementCounter :: (MonadSTM m) => Counter -> m ()
incrementCounter (Counter tVar) = liftSTM $ modifyTVar' tVar succ

decrementCounter :: (MonadSTM m) => Counter -> m ()
decrementCounter (Counter tVar) = liftSTM $ modifyTVar' tVar pred
