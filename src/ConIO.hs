{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE RecursiveDo #-}

-- |
-- Here are a few ways to use the concurrent-scope API:
--
-- @
-- example1 :: IO ()
-- example1 =
--   -- open up a concurrency scope
--   runConIO $ do
--     -- launch tasks
--     task1 <- launch action1
--     task2 <- launch action2
--     pure ()
--   -- waits until `action1` and `action2` are done
-- @
--
-- @
-- example2 :: IO ()
-- example2 =
--   -- open up a concurrency scope
--   runConIO $ do
--     -- launch task
--     task <- launch $ pure 10
--
--     -- do some work
--     let x = 10
--
--     -- wait for task to complete and get the result
--     result <- wait task
--
--     -- prints 20
--     print $ x + result
-- @
--
-- @
-- example3 :: IO ()
-- example3 =
--   -- open up a concurrency scope
--   runConIO $ do
--     -- launch task
--     task <- launch $ threadDelay 10000000
--
--     -- cancel task
--     cancel task
-- @
--
-- @
-- example4 :: IO ()
-- example4 =
--   -- open up a concurrency scope
--   runConIO $ do
--     -- launch task
--     task \<- raceTwo (threadDelay 1000000 >> pure 10) (pure 20)
--
--     -- wait for result and cancel the slower thread
--     result <- wait task
--
--     -- prints 20
--     print result
-- @
module ConIO
  ( module Core,
    module Race,
    module Workers,
    module MonadSTM,
    module Communication,
  )
where

import ConIO.Communication as Communication
import ConIO.Core as Core
import ConIO.MonadSTM as MonadSTM
import ConIO.Race as Race
import ConIO.Workers as Workers
