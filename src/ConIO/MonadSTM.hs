module ConIO.MonadSTM (MonadSTM (..)) where

import Control.Concurrent.STM
import Control.Monad.Trans.Class

-- | 'MonadSTM' is a class for all monads which can do 'STM' actions.
--
-- Keep in mind that while some monads (e.g. 'IO') can do 'STM', your 'STM' actions may not
-- be executed 'atomically' if you run them all in the 'IO' monad. Keep them together in 'STM' and
-- then use one 'liftSTM' to lift them to the 'IO' monad.
class (Monad m) => MonadSTM m where
  -- | Lift 'STM' into the monad `m`.
  --
  -- Keep in mind that 'liftSTM' may lose atomicity. `liftSTM action1 >> liftSTM action2` might not be atomic, depending on the monad `m`. Use `liftSTM (action1 >> action2)` instead.
  liftSTM :: STM a -> m a

  -- | Lift an action which can be done in 'STM' or in 'IO'.
  -- This can be useful if the 'IO' version is more performant.
  liftSTM_IO :: STM a -> IO a -> m a
  liftSTM_IO stm _ = liftSTM stm

instance MonadSTM STM where
  liftSTM = id

instance MonadSTM IO where
  liftSTM = atomically
  liftSTM_IO _ io = io

instance (MonadSTM m, MonadTrans t) => MonadSTM (t m) where
  liftSTM = lift . liftSTM
  liftSTM_IO stm io = lift $ liftSTM_IO stm io
