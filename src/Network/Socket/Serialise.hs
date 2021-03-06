{-# LANGUAGE CPP #-}
module Network.Socket.Serialise
    ( encodeSockAddr
    , decodeSockAddr
    )
where

import           Codec.Serialise (decode, encode)
import           Codec.Serialise.Decoding (Decoder, decodeListLen, decodeWord)
import           Codec.Serialise.Encoding (Encoding, encodeListLen, encodeWord)
import           Control.Applicative (liftA2)
#if !MIN_VERSION_network(3,0,0)
import           GHC.Stack (HasCallStack)
#endif
import           Network.Socket (SockAddr(..))
import qualified Network.Socket as Sock


encodeSockAddr :: SockAddr -> Encoding
encodeSockAddr = \case
    SockAddrInet portNum hostAddr ->
           encodeListLen 3
        <> encodeWord 0
        <> encodePort portNum
        <> encodeHost hostAddr

    SockAddrInet6 portNum flow hostAddr scope ->
           encodeListLen 5
        <> encodeWord 1
        <> encodePort portNum
        <> encode flow
        <> encodeHost6 hostAddr
        <> encode scope

    SockAddrUnix path ->
           encodeListLen 2
        <> encodeWord 2
        <> encode path

#if !MIN_VERSION_network(3,0,0)
    -- SockAddrCan{} ->
    _ -> canNotSupported
#endif
  where
    encodePort  = encode . fromEnum
    encodeHost  = encode . Sock.hostAddressToTuple
    encodeHost6 = encode . Sock.hostAddress6ToTuple

decodeSockAddr :: Decoder s Sock.SockAddr
decodeSockAddr = do
    pre <- liftA2 (,) decodeListLen decodeWord
    case pre of
        (3, 0) -> liftA2 SockAddrInet decodePort decodeHost
        (5, 1) -> SockAddrInet6
              <$> decodePort
              <*> decode
              <*> decodeHost6
              <*> decode
        (2, 2) -> SockAddrUnix <$> decode
        _ -> fail "Network.Socket.Serialise: Invalid wire tagging"
  where
    decodePort  = toEnum <$> decode
    decodeHost  = Sock.tupleToHostAddress <$> decode
    decodeHost6 = Sock.tupleToHostAddress6 <$> decode

--------------------------------------------------------------------------------

#if !MIN_VERSION_network(3,0,0)
canNotSupported :: HasCallStack => a
canNotSupported = error "CAN addresses not supported"
#endif
