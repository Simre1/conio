module Main (main) where

import ConIO
import Control.Concurrent
import Control.Exception
import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Foldable (traverse_)
import Data.Functor ((<&>))
import Data.IORef
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain $
    testGroup
      "tests"
      [ testCase "launch & wait" $ do
          runConIO $ do
            t1 <- launch $ pure (4 :: Int)
            t2 <- launch $ pure (4 :: Int)
            val1 <- waitTask t1
            val2 <- waitTask t2
            liftIO $ val1 @?= val2,
        testCase "launch many tasks" $ runConIO $ do
          counter <- newCounter
          tasks <- forM [1 .. 10000] $ \(i :: Int) -> do
            launch $ incrementCounter counter
          traverse_ waitTask tasks
          value <- getCounter counter
          liftIO $ value @?= 10000,
        testCase "launch really many tasks" $ runConIO $ do
          counter <- newCounter
          tasks <- forM [1 .. 100000] $ \(i :: Int) -> do
            launch $ incrementCounter counter
          traverse_ waitTask tasks
          value <- getCounter counter
          liftIO $ value @?= 100000,
        testCase "automatic wait" $ do
          ref <- newIORef (0 :: Int)
          runConIO $ do
            _ <- launch $ atomicModifyIORef' ref (\a -> (a + 1, ()))
            _ <- launch $ atomicModifyIORef' ref (\a -> (a + 1, ()))
            _ <- launch $ atomicModifyIORef' ref (\a -> (a + 1, ()))
            pure ()
          value <- readIORef ref
          value @?= 3,
        testCase "cancel task" $ do
          ref <- newIORef (0 :: Int)
          runConIO $ do
            gate <- newGate
            _ <- launch $ waitGate gate >> atomicModifyIORef' ref (\a -> (a + 1, ()))
            t2 <- launch $ waitGate gate >> atomicModifyIORef' ref (\a -> (a + 1, ()))
            _ <- launch $ waitGate gate >> atomicModifyIORef' ref (\a -> (a + 1, ()))
            cancel t2
            openGate gate
            pure ()
          value <- readIORef ref
          value @?= 2,
        testCase "cancel all tasks" $ do
          ref <- newIORef (0 :: Int)
          runConIO $ do
            gate <- newGate
            _ <- launch $ waitGate gate >> atomicModifyIORef' ref (\a -> (a + 1, ()))
            _ <- launch $ waitGate gate >> atomicModifyIORef' ref (\a -> (a + 1, ()))
            _ <- launch $ waitGate gate >> atomicModifyIORef' ref (\a -> (a + 1, ()))
            cancelAll
            openGate gate
            pure ()
          value <- readIORef ref
          value @?= 0,
        testCase "wait canceled task 1" $ do
          value <- assertConIOKillThread $ runConIO $ do
            t1 <- launch waitForever
            cancel t1
            waitTask t1
          pure (),
        testCase "wait canceled task 2" $ do
          value <- assertConIOKillThread $ runConIO $ do
            t1 <- launch waitForever
            cancelAll
            waitTask t1
          pure (),
        testCase "task error propagates to scope" $ do
          assertConIOException $ runConIO $ do
            _ <- launch undefined
            _ <- launch (pure ())
            pure (),
        testCase "scope exception kills task" $ do
          killedRef <- newIORef False
          assertSomeException $ runConIO $ do
            gate <- newGate
            _ <-
              launch $
                catch @ConIOKillThread
                  (openGate gate >> waitForever)
                  (\e -> writeIORef killedRef True >> throwIO e)
            waitGate gate
            fail "I die"
          value <- readIORef killedRef
          value @?= True,
        testCase "task exception kills other task" $ do
          killedRef <- newIORef False
          assertConIOException $ runConIO $ do
            gate <- newGate
            _ <-
              launch $
                catch @ConIOKillThread
                  (openGate gate >> waitForever)
                  (\e -> writeIORef killedRef True >> throwIO e)
            _ <- launch $ waitGate gate >> fail "I die"
            pure ()
          value <- readIORef killedRef
          value @?= True,
        testCase "race 2 actions" $ runConIO $ do
          gate1 <- newGate
          gate2 <- newGate
          t <- raceTwo (waitGate gate1 >> pure 1) (waitGate gate2 >> pure 2)
          openGate gate2
          value <- waitTask t
          liftIO $ value @?= 2,
        testCase "race many actions" $ runConIO $ do
          condition <- newVariable (-1)
          task <-
            raceMany $
              [0 .. 10000] <&> \(i :: Int) -> do
                waitVariable (== i) condition >> pure i
          writeVariable condition 5000
          value <- waitTask task
          liftIO $ value @?= 5000,
        testCase "race 2 tasks" $ runConIO $ do
          gate1 <- newGate
          gate2 <- newGate
          t1 <- launch $ waitGate gate1 >> pure 1
          t2 <- launch $ waitGate gate2 >> pure 2
          t3 <- raceTwoTasks t1 t2
          openGate gate2
          value <- waitTask t3
          liftIO $ value @?= 2,
        testCase "race with finished task" $ runConIO $ do
          gate1 <- newGate
          gate2 <- newGate
          t1 <- launch $ waitGate gate1 >> pure 1
          t2 <- launch $ waitGate gate2 >> pure 2
          openGate gate2
          _ <- waitTask t2
          t3 <- raceTwoTasks t1 t2
          value <- waitTask t3
          liftIO $ value @?= 2,
        testCase "race many tasks" $ runConIO $ do
          condition <- newVariable (-1)
          tasks <- forM [0 .. 10000] $ \(i :: Int) -> do
            launch $ waitVariable (== i) condition >> pure i
          task <- raceManyTasks tasks
          writeVariable condition 5000
          value <- waitTask task
          liftIO $ value @?= 5000,
        testCase "timeout task" $ runConIO $ do
          task :: Task () <- launch waitForever
          timedTask <- timeoutTask (Milliseconds 10) task
          value <- waitTask timedTask
          liftIO $ value @?= Nothing
      ]

assertSomeException :: IO a -> IO ()
assertSomeException action = do
  result <- try @SomeException action
  case result of
    Left _ -> return ()
    Right _ -> assertFailure "Expected SomeException, but none thrown"

assertConIOKillThread :: IO a -> IO ()
assertConIOKillThread action = do
  result <- try @ConIOKillThread action
  case result of
    Left _ -> return ()
    Right _ -> assertFailure "Expected ConIOKillThread, but none thrown"

assertConIOException :: IO a -> IO ()
assertConIOException action = do
  result <- try @ConIOException action
  case result of
    Left _ -> return ()
    Right _ -> assertFailure "Expected ConIOException, but none thrown"
