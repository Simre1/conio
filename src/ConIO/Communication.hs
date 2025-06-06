module ConIO.Communication
  ( -- ** Gate
    Gate (..),
    newGate,
    waitGate,
    openGate,

    -- ** Switch
    Switch (..),
    newSwitch,
    waitSwitch,
    setSwitch,
    unsetSwitch,
    toggleSwitch,

    -- ** Variable
    Variable (..),
    newVariable,
    waitVariable,
    writeVariable,
    getVariable,

    -- ** Counter
    Counter (..),
    newCounter,
    getCounter,
    setCounter,
    incrementCounter,
    decrementCounter,

    -- ** Queue
    Queue (..),
    newQueue,
    popQueue,
    peekQueue,
    tryPopQueue,
    tryPeekQueue,
    pushQueue,
    isEmptyQueue,
  )
where

import ConIO.MonadSTM
import Control.Concurrent.STM
import Control.Monad (void)

-- | A 'Gate' is initially closed and can be opened with 'openGate'.
newtype Gate = Gate (TMVar ())

newGate :: (MonadSTM m) => m Gate
newGate = Gate <$> liftSTM_IO newEmptyTMVar newEmptyTMVarIO

-- | Wait for the 'Gate' to open.
waitGate :: (MonadSTM m) => Gate -> m ()
waitGate (Gate mVar) = liftSTM $ readTMVar mVar

-- | Open a 'Gate'. You __cannot__ close a 'Gate'.
openGate :: (MonadSTM m) => Gate -> m ()
openGate (Gate mVar) = liftSTM $ void $ tryPutTMVar mVar ()

-- | A 'Switch' is either on or off.
newtype Switch = Switch (TVar Bool)

newSwitch :: (MonadSTM m) => Bool -> m Switch
newSwitch b = Switch <$> liftSTM_IO (newTVar b) (newTVarIO b)

-- | Wait for the switch to turn on and execute the given 'STM' at the same time.
--
-- Be mindful that 'Switch' is only guaranteed to be on during the given 'STM' action.
waitSwitch :: (MonadSTM m) => Switch -> STM a -> m a
waitSwitch (Switch tVar) m = liftSTM $ do
  a <- readTVar tVar
  if a
    then m
    else retry

-- | Turn on the 'Switch'
setSwitch :: (MonadSTM m) => Switch -> m ()
setSwitch (Switch tVar) = liftSTM $ writeTVar tVar True

-- | Turn off the 'Switch'
unsetSwitch :: (MonadSTM m) => Switch -> m ()
unsetSwitch (Switch tVar) = liftSTM $ writeTVar tVar False

-- | Toggle the 'Switch' between on/off.
toggleSwitch :: (MonadSTM m) => Switch -> m ()
toggleSwitch (Switch tVar) = liftSTM $ do
  state <- readTVar tVar
  if state
    then writeTVar tVar False
    else writeTVar tVar True

-- | A 'Variable' holds some value in a concurrency-safe manner.
newtype Variable a = Variable (TVar a)

-- | Wait until the value within the 'Variable' fulfills some condition
waitVariable :: (MonadSTM m) => (a -> Bool) -> Variable a -> m a
waitVariable myCheck (Variable tVar) = liftSTM $ do
  a <- readTVar tVar
  if (myCheck a)
    then pure a
    else retry

newVariable :: (MonadSTM m) => a -> m (Variable a)
newVariable a = Variable <$> liftSTM_IO (newTVar a) (newTVarIO a)

-- | Write a value to the 'Variable'. Keep in mind that you can do this within 'STM'.
writeVariable :: (MonadSTM m) => Variable a -> a -> m ()
writeVariable (Variable tVar) a = liftSTM $ writeTVar tVar a

-- | Get the value of the 'Variable'. Keep in mind that you can do this within 'STM'.
getVariable :: (MonadSTM m) => Variable a -> m a
getVariable (Variable tVar) = liftSTM $ readTVar tVar

-- | A 'Counter' stores an int.
newtype Counter = Counter (TVar Int)

newCounter :: (MonadSTM m) => m Counter
newCounter = Counter <$> liftSTM_IO (newTVar 0) (newTVarIO 0)

-- | Get the current value of the 'Counter'.
getCounter :: (MonadSTM m) => Counter -> m Int
getCounter (Counter tVar) = liftSTM $ readTVar tVar

-- | Set the value of the 'Counter'.
setCounter :: (MonadSTM m) => Counter -> Int -> m ()
setCounter (Counter tVar) i = liftSTM $ writeTVar tVar i

-- | Increment the 'Counter' by one.
incrementCounter :: (MonadSTM m) => Counter -> m ()
incrementCounter (Counter tVar) = liftSTM $ modifyTVar' tVar succ

-- | Decrement the 'Counter' by one.
decrementCounter :: (MonadSTM m) => Counter -> m ()
decrementCounter (Counter tVar) = liftSTM $ modifyTVar' tVar pred

-- | A 'Queue' holds zero or more values.
newtype Queue a = Queue (TChan a)

newQueue :: (MonadSTM m) => m (Queue a)
newQueue = Queue <$> liftSTM_IO newTChan newTChanIO

-- | Pop the first element of the 'Queue', removing it from the queue.
-- Waits until an element is available.
popQueue :: (MonadSTM m) => Queue a -> m a
popQueue (Queue chan) = liftSTM $ readTChan chan

-- | Get the first element of the 'Queue', __not__ removing it from the queue.
-- Waits until an element is available.
peekQueue :: (MonadSTM m) => Queue a -> m a
peekQueue (Queue chan) = liftSTM $ peekTChan chan

-- | Pop the first element of the 'Queue', removing it from the queue.
-- Does not wait and returns immediately, if no element is available.
tryPopQueue :: (MonadSTM m) => Queue a -> m (Maybe a)
tryPopQueue (Queue chan) = liftSTM $ tryReadTChan chan

-- | Get the first element of the 'Queue', __not__ removing it from the queue.
-- Does not wait and returns immediately, if no element is available.
tryPeekQueue :: (MonadSTM m) => Queue a -> m (Maybe a)
tryPeekQueue (Queue chan) = liftSTM $ tryPeekTChan chan

-- | Push an element to the back of the 'Queue'.
pushQueue :: (MonadSTM m) => Queue a -> a -> m ()
pushQueue (Queue chan) a = liftSTM $ writeTChan chan a

-- | Checks if the 'Queue' is empty.
isEmptyQueue :: (MonadSTM m) => Queue a -> m Bool
isEmptyQueue (Queue chan) = liftSTM $ isEmptyTChan chan
