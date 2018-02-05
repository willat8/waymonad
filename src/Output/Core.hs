module Output.Core
where

import Control.Monad.IO.Class (MonadIO, liftIO)

import Graphics.Wayland.WlRoots.Output (setOutputNeedsSwap)

import Utility (ptrToInt)
import Waymonad.Types (Output (..))

setOutputDirty :: MonadIO m => Output -> m ()
setOutputDirty out = liftIO $ setOutputNeedsSwap (outputRoots out) True

getOutputId :: Output -> Int
getOutputId = ptrToInt . outputRoots