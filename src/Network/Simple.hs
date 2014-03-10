{-# LANGUAGE CPP #-}

-- | This module exports functions that abstract simple TCP 'NS.Socket'
-- usage patterns.
--
-- This module uses 'MonadIO' and 'C.MonadCatch' extensively so that you can
-- reuse these functions in monads other than 'IO'. However, if you don't care
-- about any of that, just pretend you are using the 'IO' monad all the time
-- and everything will work as expected.

-- Some code in this file was adapted from the @pipes-network@ library by
-- Renzo Carbonara. Copyright (c) 2012-2013. See its licensing terms (BSD3) at:
--   https://github.com/k0001/pipes-network/blob/master/LICENSE
--
-- Some code in this file was adapted from the @network-conduit@ library by
-- Michael Snoyman. Copyright (c) 2011. See its licensing terms (BSD3) at:
--   https://github.com/snoyberg/conduit/blob/master/network-conduit/LICENSE

module Network.Simple (
  -- * Introduction to TCP networking
  -- $tcp-101

  -- * Client side
  -- $client-side
    connect

  -- * Server side
  -- $server-side
  , serve
  -- ** Listening
  , listen
  -- ** Accepting
  , accept
  , acceptFork

  -- * Utils
  , recv
  , send

  -- * Low level support
  , bindSock
  , connectSock
  , closeSock

  -- * Note to Windows users
  , NS.withSocketsDo

  -- * Types
  , HostPreference(..)
  -- ** Re-exported from @Network.Socket@
  , NS.HostName
  , NS.ServiceName
  , NS.Socket
  , NS.SockAddr
  ) where

import           Control.Concurrent             (ThreadId, forkIO)
import qualified Control.Exception              as E
import qualified Control.Monad.Catch            as C
import           Control.Monad
import           Control.Monad.IO.Class         (MonadIO(liftIO))
import qualified Data.ByteString                as BS
import           Data.List                      (partition)
import qualified Network.Socket                 as NS
import           Network.Simple.Internal
import qualified Network.Socket.ByteString      as NSB

import qualified Network.Simple.SockAddr        as NSA
import           Network.Simple.SockAddr        (accept)

--------------------------------------------------------------------------------
-- $tcp-101
--
-- This introduction aims to give you a overly simplified overview of some
-- concepts you need to know about TCP sockets in order to make effective use of
-- this module.
--
-- There are two ends in a single TCP connection: one is the TCP «server» and
-- the other is the TCP «client». Each end is uniquely identified by an IP
-- address and a TCP port pair, and each end knows the IP address and TCP port
-- of the other end. Each end can send and receive data to and from the other
-- end.
--
-- A TCP server, once «bound» to a well-known IP address and TCP port, starts
-- «listening» for incoming connections from TCP clients to such bound IP
-- address and TCP port. When a TCP client attempts to connect to the TCP
-- server, the TCP server must «accept» the incoming connection in order to
-- start exchanging data with the remote end. A single TCP server can
-- sequentially accept many incoming connections, possibly handling each one
-- concurrently.
--
-- A TCP client can «connect» to a well-known IP address and TCP port previously
-- bound by a listening TCP server willing to accept new incoming connections.
-- Once the connection is established, the TCP client can immediately start
-- exchanging data with the TCP server. The TCP client is randomly assigned a
-- TCP port when connecting, and its IP address is selected by the operating
-- system so that it is reachable from the remote end.
--
-- The TCP client a and the TCP server can be running in the same host or in
-- different hosts.

--------------------------------------------------------------------------------

-- $client-side
--
-- Here's how you could run a TCP client:
--
-- @
-- 'connect' \"www.example.org\" \"80\" $ \\(connectionSocket, remoteAddr) -> do
--   putStrLn $ \"Connection established to \" ++ show remoteAddr
--   -- Now you may use connectionSocket as you please within this scope,
--   -- possibly using 'recv' and 'send' to interact with the remote end.
-- @

-- | Connect to a TCP server and use the connection.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- If you prefer to acquire and close the socket yourself, then use
-- 'connectSock' and 'closeSock'.
connect
  :: (MonadIO m, C.MonadCatch m)
  => NS.HostName      -- ^Server hostname.
  -> NS.ServiceName   -- ^Server service port.
  -> ((NS.Socket, NS.SockAddr) -> m r)
                      -- ^Computation taking the communication socket
                      -- and the server address.
  -> m r
connect host port = C.bracket (connectSock host port)
                              (silentCloseSock . fst)

--------------------------------------------------------------------------------

-- $server-side
--
-- Here's how you can run a TCP server that handles in different threads each
-- incoming connection to port @8000@ at IPv4 address @127.0.0.1@:
--
-- @
-- 'serve' ('Host' \"127.0.0.1\") \"8000\" $ \\(connectionSocket, remoteAddr) -> do
--   putStrLn $ \"TCP connection established from \" ++ show remoteAddr
--   -- Now you may use connectionSocket as you please within this scope,
--   -- possibly using 'recv' and 'send' to interact with the remote end.
-- @
--
-- If you need more control on the way your server runs, then you can use more
-- advanced functions such as 'listen', 'accept' and 'acceptFork'.

--------------------------------------------------------------------------------

-- | Start a TCP server that accepts incoming connections and handles them
-- concurrently in different threads.
--
-- Any acquired network resources are properly closed and discarded when done or
-- in case of exceptions.
--
-- Note: This function performs 'listen' and 'acceptFork', so you don't need to
-- perform those manually.
serve
  :: (MonadIO m, C.MonadCatch m)
  => HostPreference   -- ^Preferred host to bind.
  -> NS.ServiceName   -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                      -- ^Computation to run in a different thread
                      -- once an incoming connection is accepted. Takes the
                      -- connection socket and remote end address.
  -> m ()
serve hp port k = do
    addr <- resolve (hpHostName hp) (Just port)
    NSA.serve addr k

--------------------------------------------------------------------------------

-- | Bind a TCP listening socket and use it.
--
-- The listening socket is closed when done or in case of exceptions.
--
-- If you prefer to acquire and close the socket yourself, then use 'bindSock',
-- 'closeSock' and the 'NS.listen' function from "Network.Socket" instead.
--
-- Note: 'N.maxListenQueue' is tipically 128, which is too small for high
-- performance servers. So, we use the maximum between 'N.maxListenQueue' and
-- 2048 as the default size of the listening queue. The 'NS.NoDelay' and
-- 'NS.ReuseAddr' options are set on the socket.
listen
  :: (MonadIO m, C.MonadCatch m)
  => HostPreference   -- ^Preferred host to bind.
  -> NS.ServiceName   -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> m r)
                      -- ^Computation taking the listening socket and
                      -- the address it's bound to.
  -> m r
listen hp port k = do
    addr <- resolve (hpHostName hp) (Just port)
    NSA.listen addr k

--------------------------------------------------------------------------------

-- | Accept a single incoming connection and use it in a different thread.
--
-- The connection socket is closed when done or in case of exceptions.
acceptFork
  :: MonadIO m
  => NS.Socket        -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                      -- ^Computation to run in a different thread
                      -- once an incoming connection is accepted. Takes the
                      -- connection socket and remote end address.
  -> m ThreadId
acceptFork lsock k = liftIO $ do
    conn@(csock,_) <- NS.accept lsock
    forkFinally (k conn)
                (\ea -> do silentCloseSock csock
                           either E.throwIO return ea)
{-# INLINABLE acceptFork #-}

--------------------------------------------------------------------------------

-- | Obtain a 'NS.Socket' connected to the given host and TCP service port.
--
-- The obtained 'NS.Socket' should be closed manually using 'closeSock' when
-- it's not needed anymore, otherwise you risk having the socket open for much
-- longer than needed.
--
-- Prefer to use 'connect' if you will be using the socket within a limited
-- scope and would like it to be closed immediately after its usage or in case
-- of exceptions.
connectSock :: (MonadIO m, C.MonadCatch m)
            => NS.HostName -> NS.ServiceName -> m (NS.Socket, NS.SockAddr)
connectSock host port = do
    addr <- resolve (Just host) (Just port)
    liftIO $ E.bracketOnError (NSA.newSocket addr) closeSock $ \sock -> do
        liftIO $ NS.connect sock addr
        return (sock, addr)

-- | Obtain a 'NS.Socket' bound to the given host name and TCP service port.
--
-- The obtained 'NS.Socket' should be closed manually using 'closeSock' when
-- it's not needed anymore.
--
-- Prefer to use 'listen' if you will be listening on this socket and using it
-- within a limited scope, and would like it to be closed immediately after its
-- usage or in case of exceptions.
bindSock :: (MonadIO m, C.MonadCatch m)
         => HostPreference -> NS.ServiceName -> m (NS.Socket, NS.SockAddr)
bindSock hp port = resolve (hpHostName hp) (Just port) >>= NSA.bindSock

-- | Close the 'NS.Socket'.
closeSock :: MonadIO m => NS.Socket -> m ()
closeSock = liftIO .
#if MIN_VERSION_network(2,4,0)
    NS.close
#else
    NS.sClose
#endif
{-# INLINE closeSock #-}

--------------------------------------------------------------------------------
-- Utils

-- | Read up to a limited number of bytes from a socket.
--
-- Returns `Nothing` if the remote end closed the connection or end-of-input was
-- reached. The number of returned bytes might be less than the specified limit.
recv :: MonadIO m => NS.Socket -> Int -> m (Maybe BS.ByteString)
recv sock nbytes = do
     bs <- liftIO (NSB.recv sock nbytes)
     if BS.null bs
        then return Nothing
        else return (Just bs)
{-# INLINABLE recv #-}

-- | Writes the given bytes to the socket.
send :: MonadIO m => NS.Socket -> BS.ByteString -> m ()
send sock = \bs -> liftIO (NSB.sendAll sock bs)
{-# INLINABLE send #-}

--------------------------------------------------------------------------------

-- Misc

newSocket :: NS.AddrInfo -> IO NS.Socket
newSocket addr = NS.socket (NS.addrFamily addr)
                           (NS.addrSocketType addr)
                           (NS.addrProtocol addr)

isIPv4addr, isIPv6addr :: NS.AddrInfo -> Bool
isIPv4addr x = NS.addrFamily x == NS.AF_INET
isIPv6addr x = NS.addrFamily x == NS.AF_INET6

-- | Move the elements that match the predicate closer to the head of the list.
-- Sorting is stable.
prioritize :: (a -> Bool) -> [a] -> [a]
prioritize p = uncurry (++) . partition p


--------------------------------------------------------------------------------

-- | 'Control.Concurrent.forkFinally' was introduced in base==4.6.0.0. We'll use
-- our own version here for a while, until base==4.6.0.0 is widely establised.
forkFinally :: IO a -> (Either E.SomeException a -> IO ()) -> IO ThreadId
forkFinally action and_then =
    E.mask $ \restore ->
        forkIO $ E.try (restore action) >>= and_then


-- | Like 'closeSock', except it swallows all 'IOError' exceptions.
silentCloseSock :: MonadIO m => NS.Socket -> m ()
silentCloseSock sock = liftIO $ do
    E.catch (closeSock sock)
            (\e -> let _ = e :: IOError in return ())

resolve :: (MonadIO m, C.MonadCatch m) => Maybe NS.HostName -> Maybe NS.ServiceName -> m NS.SockAddr
resolve = undefined
    -- addrs <- NS.getAddrInfo (Just hints) (hpHostName hp) (Just port)
    -- let addrs' = case hp of
    --       HostIPv4 -> prioritize isIPv4addr addrs
    --       HostIPv6 -> prioritize isIPv6addr addrs
    --       _        -> addrs
    -- tryAddrs addrs'
  -- where
    -- hints = NS.defaultHints { NS.addrFlags = [NS.AI_PASSIVE]
    --                         , NS.addrSocketType = NS.Stream }

    -- tryAddrs []     = error "bindSock: no addresses available"
    -- tryAddrs [x]    = useAddr x
    -- tryAddrs (x:xs) = E.catch (useAddr x)
    --                           (\e -> let _ = e :: IOError in tryAddrs xs)

    -- useAddr addr = E.bracketOnError (newSocket addr) closeSock $ \sock -> do
    --   let sockAddr = NS.addrAddress addr
    --   NS.setSocketOption sock NS.NoDelay 1
    --   NS.setSocketOption sock NS.ReuseAddr 1
    --   NS.bindSocket sock sockAddr
    -- -liftIO $ do
    -- (addr:_) <- NS.getAddrInfo (Just hints) (Just host) (Just port)
    -- E.bracketOnError (newSocket addr) closeSock $ \sock -> do
    --    let sockAddr = NS.addrAddress addr
    --    NS.connect sock sockAddr
    --    return (sock, sockAddr)
  -- where
    -- hints = NS.defaultHints { NS.addrFlags = [NS.AI_ADDRCONFIG]
    --                         , NS.addrSocketType = NS.Stream }-   return (sock, sockAddr)
