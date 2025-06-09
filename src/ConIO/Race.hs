{-# LANGUAGE RecursiveDo #-}

module ConIO.Race
  ( -- ** Race
    raceTwo,
    raceTwoMaybe,
    raceMany,
    raceManyMaybe,
    raceTwoTasks,
    raceTwoTasksMaybe,
    raceManyTasks,
    raceManyTasksMaybe,

    -- ** Timeout
    timeout,
    timeoutTask,

    -- ** Waiting
    waitDuration,
    waitForever,

    -- ** Duration
    Duration,
    fromSeconds,
    fromMilliseconds,
    fromMicroseconds,
    durationToMicroseconds,
  )
where

import ConIO.Core
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad (forever, void, when)
import Control.Monad.IO.Class
import Data.Foldable (traverse_)
import Data.Traversable (forM)

-- | Race two actions. The slower is canceled.
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

-- | Race two actions which may produce results. If one action produces a result, the other one is cancelled.
-- If no actions produce a result, then the resulting task also produces nothing.
raceTwoMaybe :: IO (Maybe a) -> IO (Maybe a) -> ConIO (Task (Maybe a))
raceTwoMaybe action1 action2 = mdo
  result <- liftIO (newTVarIO Nothing)
  counter <- liftIO $ newTVarIO (2 :: Int)
  task1 <- launch $ do
    maybeValue1 <- action1
    atomically $ modifyTVar' counter pred
    case maybeValue1 of
      Just value1 -> do
        wasPut <- atomically $ do
          currentResult <- readTVar result
          case currentResult of
            Nothing -> writeTVar result (Just value1) >> pure True
            Just _ -> pure False
        when wasPut $ cancel task2
      Nothing -> pure ()
  task2 <- launch $ do
    maybeValue2 <- action2
    atomically $ modifyTVar' counter pred
    case maybeValue2 of
      Just value2 -> do
        wasPut <- atomically $ do
          currentResult <- readTVar result
          case currentResult of
            Nothing -> writeTVar result (Just value2) >> pure True
            Just _ -> pure False
        when wasPut $ cancel task1
      Nothing -> pure ()
  pure $
    Task
      { payload = do
          currentResult <- readTVar result
          case currentResult of
            Just r -> pure $ Just r
            Nothing -> do
              currentCounter <- readTVar counter
              if currentCounter == 0
                then pure Nothing
                else retry,
        threadIds = task1.threadIds <> task2.threadIds
      }

-- | Race many actions which may produce results. If one action produces a result, the other ones are cancelled.
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
        useConScope scope $ void $ launch $ traverse cancel tasks
    pure task
  liftIO $ putMVar tasksMVar tasks
  pure $
    Task
      { payload = readTMVar raceResult,
        threadIds = foldMap (.threadIds) tasks
      }

-- | Race many actions. The slower ones are canceled.
-- If no actions produce a result, then the resulting task will also produce nothing.
raceManyMaybe :: (Traversable t) => t (IO (Maybe a)) -> ConIO (Task (Maybe a))
raceManyMaybe actions = do
  raceResult <- liftIO newEmptyTMVarIO
  counter <- liftIO (newTVarIO (length actions))
  tasks <- withConScope $ \scope -> forM actions $ \action -> do
    task <- useConScope scope $ launch $ do
      maybeResult <- action
      atomically $ modifyTVar' counter pred
      case maybeResult of
        Just result -> atomically $ tryPutTMVar raceResult (Just result)
        Nothing -> pure False
    pure task
  cancellerTask <- launch $ do
    shouldCancel <- atomically $ do
      currentRaceResult <- tryReadTMVar raceResult
      case currentRaceResult of
        Just _ -> pure True
        Nothing -> do
          currentCounter <- readTVar counter
          if currentCounter == 0
            then do
              putTMVar raceResult Nothing
              pure False
            else retry
    when shouldCancel $ traverse_ cancel tasks
  pure $
    Task
      { payload = readTMVar raceResult,
        threadIds = foldMap (.threadIds) tasks <> cancellerTask.threadIds
      }

-- | Time out an action.
timeout :: Duration -> IO a -> ConIO (Maybe a)
timeout duration action = do
  t <- raceTwo (Just <$> action) (threadDelay maxWaitTime >> pure Nothing)
  wait t
  where
    maxWaitTime = fromIntegral $ durationToMicroseconds duration

-- | Race two already started 'Task's. The slower one is cancelled.
--
-- Keep in mind that cancelling the resulting 'Task' will cancel both given 'Task's.
raceTwoTasks :: Task a -> Task a -> ConIO (Task a)
raceTwoTasks task1 task2 = mdo
  result <- liftIO newEmptyMVar
  checkTask1 <- launch $ do
    value1 <- wait task1
    wasPut <- tryPutMVar result value1
    when wasPut $ cancel task2 >> cancel checkTask2
  checkTask2 <- launch $ do
    value2 <- wait task2
    wasPut <- tryPutMVar result value2
    when wasPut $ cancel task1 >> cancel checkTask1
  task <- launch $ takeMVar result
  pure $
    Task
      { payload = wait task,
        threadIds =
          task.threadIds
            <> foldMap (.threadIds) [task1, task2]
            <> foldMap (.threadIds) [checkTask1, checkTask2]
      }

-- | Race already started 'Task's and use the first produced Just value. The slower task is cancelled.
--
-- Keep in mind that cancelling the resulting 'Task' will cancel both given 'Task's.
raceTwoTasksMaybe :: Task (Maybe a) -> Task (Maybe a) -> ConIO (Task (Maybe a))
raceTwoTasksMaybe task1 task2 = raceManyTasksMaybe [task1, task2]

-- | Race already started 'Task's. The slower ones are cancelled.
--
-- Keep in mind that cancelling the resulting 'Task' will all given 'Task's.
raceManyTasks :: (Traversable t) => t (Task a) -> ConIO (Task a)
raceManyTasks tasks = do
  raceResult <- liftIO newEmptyMVar
  checkTasks <- forM tasks $ \task -> do
    checkTask <- launch $ do
      result <- wait task
      tryPutMVar raceResult result
    pure checkTask
  task <- launch $ do
    a <- takeMVar raceResult
    traverse_ cancel tasks
    traverse_ cancel checkTasks
    pure a
  pure $
    Task
      { payload = wait task,
        threadIds =
          task.threadIds
            <> foldMap (.threadIds) tasks
            <> foldMap (.threadIds) checkTasks
      }

-- | Race already started 'Task's and use the first produced Just value. The slower tasks are cancelled.
--
-- Keep in mind that cancelling the resulting 'Task' will all given 'Task's.
raceManyTasksMaybe :: (Traversable t) => t (Task (Maybe a)) -> ConIO (Task (Maybe a))
raceManyTasksMaybe tasks = do
  raceResult <- liftIO newEmptyTMVarIO
  counter <- liftIO (newTVarIO (length tasks))
  checkTasks <- withConScope $ \scope -> forM tasks $ \task -> do
    task <- useConScope scope $ launch $ do
      maybeResult <- wait task
      atomically $ modifyTVar' counter pred
      case maybeResult of
        Just result -> atomically $ tryPutTMVar raceResult (Just result)
        Nothing -> pure False
    pure task
  cancellerTask <- launch $ do
    shouldCancel <- atomically $ do
      currentRaceResult <- tryReadTMVar raceResult
      case currentRaceResult of
        Just _ -> pure True
        Nothing -> do
          currentCounter <- readTVar counter
          if currentCounter == 0
            then do
              putTMVar raceResult Nothing
              pure False
            else retry
    when shouldCancel $ do
      traverse_ cancel tasks
      traverse_ cancel checkTasks
  pure $
    Task
      { payload = readTMVar raceResult,
        threadIds = foldMap (.threadIds) tasks <> foldMap (.threadIds) checkTasks <> cancellerTask.threadIds
      }

-- | Time out a 'Task', counting the 'Duration' down from the moment that 'timeoutTask' is executed.
-- The total runtime of the 'Task' does not matter.
timeoutTask :: Duration -> Task a -> ConIO (Task (Maybe a))
timeoutTask duration task = do
  timer <- launch (threadDelay maxWaitTime >> pure Nothing)
  raceTwoTasks (Just <$> task) timer
  where
    maxWaitTime = fromIntegral $ durationToMicroseconds duration

-- | Waits forever
waitDuration :: (MonadIO m) => Duration -> m ()
waitDuration duration = liftIO $ threadDelay $ fromIntegral $ durationToMicroseconds duration

-- | Waits forever
waitForever :: (MonadIO m) => m a
waitForever = liftIO $ forever (threadDelay maxBound)

-- | 'Duration' is a time span. It is used for waiting and timeouts.
newtype Duration = Duration Word deriving (Show, Eq, Ord, Num)

-- | Create a 'Duration' from seconds
fromSeconds :: Word -> Duration
fromSeconds w = Duration $ w * 1000000

-- | Create a 'Duration' from milliseconds
fromMilliseconds :: Word -> Duration
fromMilliseconds w = Duration $ w * 1000

-- | Create a 'Duration' from microseconds
fromMicroseconds :: Word -> Duration
fromMicroseconds w = Duration w

-- Get the 'Duration' in microseconds.
durationToMicroseconds :: Duration -> Word
durationToMicroseconds (Duration w) = w
