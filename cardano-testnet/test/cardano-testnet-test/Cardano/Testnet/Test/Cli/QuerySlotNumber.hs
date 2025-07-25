{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Redundant id" #-}

module Cardano.Testnet.Test.Cli.QuerySlotNumber
  ( hprop_querySlotNumber
  ) where

import           Cardano.Ledger.Shelley.Genesis (fromNominalDiffTimeMicro)
import           Cardano.Slotting.Slot
import           Cardano.Slotting.Time (SystemStart (..))
import           Cardano.Testnet

import           Prelude

import           Data.Default.Class
import           Data.Either
import qualified Data.Time.Clock as DT
import qualified Data.Time.Format as DT
import qualified System.Info as SYS

import           Testnet.Process.Run (execCli', mkExecConfig)
import           Testnet.Property.Util (integrationRetryWorkspace)
import           Testnet.Types

import           Hedgehog (Property)
import qualified Hedgehog.Extras.Stock as H
import qualified Hedgehog.Extras.Test.Base as H
import qualified Hedgehog.Extras.Test.TestWatchdog as H
import qualified Hedgehog.Internal.Property as H

-- | Tests @query slot-number@ cardano-cli command that it returns correct slot numbers for provided utc time
hprop_querySlotNumber :: Property
hprop_querySlotNumber = integrationRetryWorkspace 2 "query-slot-number" $ \tempAbsBasePath' -> H.runWithDefaultWatchdog_ $ do
  H.note_ SYS.os
  conf <- mkConf tempAbsBasePath'

  let tempBaseAbsPath' = makeTmpBaseAbsPath $ tempAbsPath conf

  tr@TestnetRuntime
    { testnetMagic
    , testnetNodes
    } <- createAndRunTestnet def def conf
  ShelleyGenesis{sgSlotLength, sgEpochLength} <- H.noteShowM $ shelleyGenesis tr
  SystemStart startTime <- H.noteShowM $ getStartTime tempAbsBasePath' tr

  let slotLength = fromNominalDiffTimeMicro sgSlotLength
      -- how many slots can the checked value differ from
      -- we have 1s precision for UTC timestamp CLI argument, so this value tells how many slots in 1s can be
      slotPrecision = round $ 1 / slotLength
      epochSize = fromIntegral (unEpochSize sgEpochLength) :: Int

  poolNode1 <- H.headM testnetNodes
  poolSprocket1 <- H.noteShow $ nodeSprocket poolNode1
  execConfig <- mkExecConfig tempBaseAbsPath' poolSprocket1 testnetMagic

  id do
    H.note_ "Try to retrieve slot 5s before genesis"
    testTime <- H.note . formatTime $ (-5) `DT.addUTCTime` startTime
    (result, _) <- H.runTestT $ execCli' execConfig
      [ "latest", "query", "slot-number"
      , testTime
      ]
    H.assertWith result isLeft

  id do
    H.note_ "Retrieve slot number for the start time"
    testTime <- H.note $ formatTime startTime
    let expectedSlot = 0
    slot <- H.readNoteM =<< execCli' execConfig
      [ "latest", "query", "slot-number"
      , testTime
      ]
    H.assertWithinTolerance slot expectedSlot slotPrecision

  id do
    H.note_ "Retrieve slot number for some delay"
    let expectedSlot = 200
        passedTime = fromIntegral expectedSlot * slotLength
    testTime <- H.note . formatTime $ passedTime `DT.addUTCTime` startTime
    slot <- H.readNoteM @Int =<< execCli' execConfig
      [ "latest", "query", "slot-number"
      , testTime
      ]
    H.assertWithinTolerance slot expectedSlot slotPrecision

  id do
    H.note_ "Retrieve slot number at the end of epoch"
    -- that's the last slot we can look up
    -- for detailed explanation about the horizon limit see:
    -- https://github.com/input-output-hk/ouroboros-consensus/pull/62
    let expectedSlot = epochSize - 1
        passedTime = fromIntegral expectedSlot * slotLength
    testTime <- H.note . formatTime $ passedTime `DT.addUTCTime` startTime
    slot <- H.readNoteM @Int =<< execCli' execConfig
      [ "latest", "query", "slot-number"
      , testTime
      ]
    H.assertWithinTolerance slot expectedSlot slotPrecision

  id do
    H.note_ "Try to retrieve slot beyond the horizon"
    let timeOffset = slotLength * fromIntegral epochSize * 2
    testTime <- H.note . formatTime $ timeOffset `DT.addUTCTime` startTime
    (result, _) <- H.runTestT $ execCli' execConfig
      [ "latest", "query", "slot-number"
      , testTime
      ]
    H.assertWith result isLeft

formatTime :: DT.UTCTime -> String
formatTime = DT.formatTime DT.defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

