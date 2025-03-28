{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Spec.Chairman.Chairman
  ( chairmanOver
  ) where

import           Cardano.Api (unFile)

import           Cardano.Testnet (TmpAbsolutePath (TmpAbsolutePath), makeLogDir)
import qualified Cardano.Testnet as H

import           Control.Monad (when)
import           Data.Functor ((<&>))
import           GHC.Stack
import qualified System.Environment as IO
import           System.Exit (ExitCode (..))
import           System.FilePath.Posix ((</>))
import qualified System.IO as IO
import qualified System.Process as IO

import           Testnet.Types (TestnetNode, nodeSocketPath)

import qualified Hedgehog as H
import           Hedgehog.Extras.Test.Base (Integration)
import qualified Hedgehog.Extras.Test.Base as H
import qualified Hedgehog.Extras.Test.File as H
import qualified Hedgehog.Extras.Test.Process as H

{- HLINT ignore "Redundant <&>" -}

chairmanOver :: HasCallStack => Int -> Int -> H.Conf -> [TestnetNode] -> Integration ()
chairmanOver timeoutSeconds requiredProgress H.Conf {H.tempAbsPath} allNodes = do
  maybeChairman <- H.evalIO $ IO.lookupEnv "DISABLE_CHAIRMAN"
  let tempAbsPath' = H.unTmpAbsPath tempAbsPath
      logDir = makeLogDir $ TmpAbsolutePath tempAbsPath'
      tempBaseAbsPath = H.makeTmpBaseAbsPath $ TmpAbsolutePath tempAbsPath'
  when (maybeChairman /= Just "1") $ do
    nodeStdoutFile <- H.noteTempFile logDir $ "chairman" <> ".stdout.log"
    nodeStderrFile <- H.noteTempFile logDir $ "chairman" <> ".stderr.log"

    sprockets <- H.noteEach $ unFile . nodeSocketPath <$> allNodes

    hNodeStdout <- H.evalIO $ IO.openFile nodeStdoutFile IO.WriteMode
    hNodeStderr <- H.evalIO $ IO.openFile nodeStderrFile IO.WriteMode

    (_, _, _, hProcess, _) <- H.createProcess =<<
      ( H.procChairman
        ( [ "--timeout", show @Int timeoutSeconds
          , "--config", tempAbsPath' </> "configuration.yaml"
          , "--require-progress", show @Int requiredProgress
          ]
        <> (sprockets >>= (\sprocket -> ["--socket-path", sprocket]))
        ) <&>
        ( \cp -> cp
          { IO.std_in = IO.CreatePipe
          , IO.std_out = IO.UseHandle hNodeStdout
          , IO.std_err = IO.UseHandle hNodeStderr
          , IO.cwd = Just tempBaseAbsPath
          }
        )
      )
    chairmanResult <- H.waitSecondsForProcess (timeoutSeconds + 60) hProcess

    case chairmanResult of
      Right ExitSuccess -> return ()
      _ -> do
        H.note_ $ "Chairman failed with: " <> show chairmanResult
        H.cat nodeStdoutFile
        H.cat nodeStderrFile
        H.failure
