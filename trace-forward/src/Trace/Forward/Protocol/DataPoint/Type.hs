{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeFamilies #-}

-- | The type of the 'DataPoint' forwarding/accepting protocol.
--

module Trace.Forward.Protocol.DataPoint.Type
  ( DataPointName
  , DataPointValue
  , DataPointValues
  , DataPointForward (..)
  , Message (..)
  , SingDataPointForward (..)
  ) where

import           Cardano.Logging.Tracer.DataPoint (DataPointName)
import           Ouroboros.Network.Util.ShowProxy (ShowProxy (..))

import qualified Data.ByteString.Lazy as LBS
import           Data.Kind (Type)
import           Data.Singletons
import           Network.TypedProtocol.Core

-- | A kind to identify our protocol, and the types of the states in the state
-- transition diagram of the protocol.
--
-- IMPORTANT NOTE: the following terminology is used:
--
-- 1. From the protocol's point of view, two peers talk to each other:
--    the forwarder and the acceptor.
-- 2. The forwarder is an application that collects 'DataPoint's and sends
--    them to the acceptor by request (with 'MsgDataPointsReply').
-- 3. The acceptor is an application that receives 'DataPoint's from the
--    forwarder.
-- 4. You can think of the acceptor as a client, and the forwarder as a server.
--    After the connection is established, the acceptor asks for 'DataPoint's,
--    the forwarder replies to it.

type DataPointValue  = LBS.ByteString
type DataPointValues = [(DataPointName, Maybe DataPointValue)]

data DataPointForward where

  -- | Both acceptor and forwarder are in idle state. The acceptor can send a
  -- request  for a list of 'DataPoint's ('MsgDataPointsRequest');
  -- the forwarder is waiting for a request, it will reply with 'MsgDataPointsReply'.
  StIdle :: DataPointForward

  -- | The acceptor has sent a next request for 'DataPoint's. The acceptor is
  -- now waiting for a reply, and the forwarder is busy getting ready to send a
  -- reply with new list of 'DataPoint's.
  StBusy :: DataPointForward

  -- | Both the acceptor and forwarder are in the terminal state. They're done.
  StDone :: DataPointForward

instance ShowProxy DataPointForward where
  showProxy _ = "DataPointForward"

-- | Singleton type of DataPointForward. Same as:
--
-- @
-- type SingDataPointForward :: DataPointForward -> Type
-- type SingDataPointForward = TypeRep
-- @
type SingDataPointForward :: DataPointForward -> Type
data SingDataPointForward dataPoint where
  SingIdle :: SingDataPointForward 'StIdle
  SingBusy :: SingDataPointForward 'StBusy
  SingDone :: SingDataPointForward 'StDone

type instance Sing = SingDataPointForward

deriving instance Show (SingDataPointForward st)
instance StateTokenI 'StIdle where stateToken = SingIdle
instance StateTokenI 'StBusy where stateToken = SingBusy
instance StateTokenI 'StDone where stateToken = SingDone

instance Protocol DataPointForward where

  -- | The messages in the trace forwarding/accepting protocol.
  --
  data Message DataPointForward from to where
    -- | Request the list of 'DataPoint's from the forwarder.
    --   State: Idle -> Busy.
    MsgDataPointsRequest
      :: [DataPointName]
      -> Message DataPointForward 'StIdle 'StBusy

    -- | Reply with a list of 'DataPoint's for the acceptor.
    -- State: Busy -> Idle.
    MsgDataPointsReply
      :: DataPointValues
      -> Message DataPointForward 'StBusy 'StIdle

    -- | Terminating message. State: Idle -> Done.
    MsgDone
      :: Message DataPointForward 'StIdle 'StDone

  -- | This is an explanation of our states, in terms of which party has agency
  -- in each state.
  --
  -- 1. When both peers are in Idle state, the acceptor can send a message
  --    to the forwarder (request for new 'DataPoint's),
  -- 2. When both peers are in Busy state, the forwarder is expected to send
  --    a reply to the acceptor (list of new 'DataPoint's).
  --
  -- So we assume that, from __interaction__ point of view:
  -- 1. ClientHasAgency (from 'Network.TypedProtocol.Core') corresponds to acceptor's agency.
  -- 3. ServerHasAgency (from 'Network.TypedProtocol.Core') corresponds to forwarder's agency.
  --
  type StateAgency 'StIdle = 'ClientAgency
  type StateAgency 'StBusy = 'ServerAgency
  type StateAgency 'StDone = 'NobodyAgency

  type StateToken = SingDataPointForward

deriving
  instance Show (Message DataPointForward from to)
