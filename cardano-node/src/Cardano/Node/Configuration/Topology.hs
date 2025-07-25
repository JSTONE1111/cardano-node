{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Cardano.Node.Configuration.Topology
  ( TopologyError(..)
  , NetworkTopology(..)
  , NodeHostIPAddress(..)
  , NodeHostIPv4Address(..)
  , NodeHostIPv6Address(..)
  , NodeSetup(..)
  , RemoteAddress(..)
  , nodeAddressToSockAddr
  , readTopologyFile
  , readTopologyFileOrError
  , remoteAddressToNodeAddress
  )
where

import           Cardano.Node.Configuration.NodeAddress
import           Cardano.Node.Configuration.POM (NodeConfiguration (..))
import           Cardano.Node.Types
import           Ouroboros.Consensus.Util.Condense (Condense (..))

import           Control.Exception (Exception (..), IOException)
import qualified Control.Exception as Exception
import           Data.Aeson
import           Data.Bifunctor (Bifunctor (..))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import           Data.Foldable
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Word (Word64)
import           GHC.Generics (Generic)
import           Text.Read (readMaybe)


newtype TopologyError
  = NodeIdNotFoundInToplogyFile FilePath
  deriving Show

-- | Domain name with port number
--
data RemoteAddress = RemoteAddress
  { raAddress   :: !Text
  -- ^ Either a dns address or an ip address.
  , raPort      :: !PortNumber
  -- ^ Port number of the destination.
  , raValency :: !Int
  -- ^ If a DNS address is given valency governs
  -- to how many resolved IP addresses
  -- should we maintain active (hot) connection;
  -- if an IP address is given valency is used as
  -- a Boolean value, @0@ means to ignore the address;
  } deriving (Eq, Ord, Show)

-- | Parse 'raAddress' field as an IP address; if it parses and the valency is
-- non zero return corresponding NodeAddress.
--
remoteAddressToNodeAddress
  :: RemoteAddress
  -> Maybe (Either NodeIPAddress
                   (NodeDnsAddress, Int))
remoteAddressToNodeAddress (RemoteAddress _addrText _port 0) =
    Nothing
remoteAddressToNodeAddress (RemoteAddress addrText port valency) =
    case readMaybe (Text.unpack addrText) of
      Nothing   -> Just $ Right (NodeAddress (NodeHostDnsAddress addrText) port
                                , valency)
      Just addr -> Just $ Left  (NodeAddress (NodeHostIPAddress addr) port)


instance Condense RemoteAddress where
  condense (RemoteAddress addr port val) =
    Text.unpack addr ++ ":" ++ show port ++ " (" ++ show val ++ ")"

instance FromJSON RemoteAddress where
  parseJSON = withObject "RemoteAddress" $ \v ->
    RemoteAddress
      <$> v .: "addr"
      <*> ((fromIntegral :: Int -> PortNumber) <$> v .: "port")
      <*> v .: "valency"

instance ToJSON RemoteAddress where
  toJSON ra =
    object
      [ "addr" .= raAddress ra
      , "port" .= (fromIntegral (raPort ra) :: Int)
      , "valency" .= raValency ra
      ]

data NodeSetup adr = NodeSetup
  { nodeId :: !Word64
  , nodeIPv4Address :: !(Maybe NodeIPv4Address)
  , nodeIPv6Address :: !(Maybe NodeIPv6Address)
  , producers :: ![adr]
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

instance (FromJSON adr) => FromJSON (NodeSetup adr) where
  parseJSON = withObject "NodeSetup" $ \o ->
                NodeSetup
                  <$> o .: "nodeId"
                  <*> o .: "nodeIPv4Address"
                  <*> o .: "nodeIPv6Address"
                  <*> o .: "producers"

instance (ToJSON adr) => ToJSON (NodeSetup adr) where
  toJSON ns =
    object
      [ "nodeId" .= nodeId ns
      , "nodeIPv4Address" .= nodeIPv4Address ns
      , "nodeIPv6Address" .= nodeIPv6Address ns
      , "producers" .= producers ns
      ]

-- | Describes the non-P2P topology of a node. Whenever the node actually runs,
-- the type parameter `adr` should be `RemoteAddress`. However, we might want to
-- use and serialize this type with `adr` being `NodeId`, or another placeholder
-- type, if we want the user to be able to edit the topology without knowing the
-- actual addresses of the nodes: those might only be knowable at runtime.
data NetworkTopology adr
  = MockNodeTopology ![NodeSetup adr]
  | RealNodeTopology ![adr]
  deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

instance (FromJSON adr) => FromJSON (NetworkTopology adr) where
  parseJSON = withObject "NetworkTopology" $ \o -> asum
                [ MockNodeTopology <$> o .: "MockProducers"
                , RealNodeTopology <$> o .: "Producers"
                ]

instance (ToJSON adr) => ToJSON (NetworkTopology adr) where
  toJSON top =
    case top of
      MockNodeTopology nss -> object [ "MockProducers" .= toJSON nss ]
      RealNodeTopology ras -> object [ "Producers" .= toJSON ras ]

-- | Read the `NetworkTopology` configuration from the specified file.
-- While running a real protocol, this gives your node its own address and
-- other remote peers it will attempt to connect to.
readTopologyFile :: ()
  => (FromJSON  adr)
  => NodeConfiguration
  -> IO (Either Text (NetworkTopology adr))
readTopologyFile nc = do
  eBs <- Exception.try $ BS.readFile (unTopology $ ncTopologyFile nc)

  case eBs of
    Left e -> return . Left $ handler e
    Right bs -> return . first handlerJSON . eitherDecode $ LBS.fromStrict bs

 where
  handler :: IOException -> Text
  handler e = Text.pack $ "Cardano.Node.Configuration.Topology.readTopologyFile: "
                        ++ displayException e
  handlerJSON :: String -> Text
  handlerJSON err = mconcat
    [ "Is your topology file formatted correctly? "
    , "Expecting Non-P2P Topology file format. "
    , "The port and valency fields should be numerical. "
    , "If you specified the correct topology file "
    , "make sure that you correctly setup EnableP2P "
    , "configuration flag. "
    , Text.pack err
    ]

readTopologyFileOrError :: ()
  => (FromJSON adr)
  => NodeConfiguration
  -> IO (NetworkTopology adr)
readTopologyFileOrError nc =
      readTopologyFile nc
  >>= either (\err -> error $ "Cardano.Node.Configuration.Topology.readTopologyFile: "
                           <> Text.unpack err)
             pure
