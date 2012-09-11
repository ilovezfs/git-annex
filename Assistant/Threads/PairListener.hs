{- git-annex assistant thread to listen for incoming pairing traffic
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Assistant.Threads.PairListener where

import Assistant.Common
import Assistant.Pairing
import Assistant.Pairing.Network
import Assistant.Pairing.MakeRemote
import Assistant.ThreadedMonad
import Assistant.ScanRemotes
import Assistant.DaemonStatus
import Assistant.WebApp
import Assistant.WebApp.Types
import Assistant.Alert
import Utility.Verifiable
import Utility.Tense

import Network.Multicast
import Network.Socket
import qualified Data.Text as T

thisThread :: ThreadName
thisThread = "PairListener"

pairListenerThread :: ThreadState -> DaemonStatusHandle -> ScanRemoteMap -> UrlRenderer -> NamedThread
pairListenerThread st dstatus scanremotes urlrenderer = thread $ withSocketsDo $ do
	sock <- multicastReceiver (multicastAddress $ IPv4Addr undefined) pairingPort
	go sock
	where
		thread = NamedThread thisThread
		
		go sock = do
			msg <- getmsg sock []
			dispatch $ readish msg
			go sock

		getmsg sock c = do
			(msg, n, _) <- recvFrom sock chunksz
			if n < chunksz
				then return $ c ++ msg
				else getmsg sock $ c ++ msg
			where
				chunksz = 1024

		dispatch Nothing = noop
		dispatch (Just m@(PairMsg v)) = do
			pip <- pairingInProgress <$> getDaemonStatus dstatus
			let verified = maybe False (verify v . inProgressSecret) pip
			case pairMsgStage m of
				PairReq -> pairReqReceived verified dstatus urlrenderer m
				PairAck -> pairAckReceived verified pip st dstatus scanremotes m
				PairDone -> pairDoneReceived verified pip st dstatus scanremotes m

{- Show an alert when a PairReq is seen.
 -
 - Pair request alerts from the same host combine,
 - so repeated requests do not add additional alerts. -}
pairReqReceived :: Bool -> DaemonStatusHandle -> UrlRenderer -> PairMsg -> IO ()
pairReqReceived True _ _ _ = noop -- ignore out own PairReq
pairReqReceived False dstatus urlrenderer msg = do
	url <- renderUrl urlrenderer (FinishPairR msg) []
	void $ addAlert dstatus $ pairRequestReceivedAlert repo
		(repo ++ " is sending a pair request.") $
		AlertButton
			{ buttonUrl = url
			, buttonLabel = T.pack "Respond"
			, buttonAction = Just onclick
			}
	where
		pairdata = pairMsgData msg
		repo = concat
			[ remoteUserName pairdata
			, "@"
			, fromMaybe (showAddr $ pairMsgAddr msg)
				(remoteHostName pairdata)
			, ":"
			, (remoteDirectory pairdata)
			]
		{- Remove the button when it's clicked, and change the
		 - alert to be in progress. This alert cannot be entirely
		 - removed since more pair request messages are coming in
		 - and would re-add it. -}
		onclick i = updateAlert dstatus i $ \alert -> Just $ alert
			{ alertButton = Nothing
			, alertClass = Activity
			, alertIcon = Just ActivityIcon
			, alertData = [UnTensed $ T.pack $ "pair request with " ++ repo ++ " in progress"]
			}

{- When a verified PairAck is seen, a host is ready to pair with us, and has
 - already configured our ssh key. Stop sending PairReqs, finish the pairing,
 - and send a few PairDones.
 -
 - TODO: A stale PairAck might also be seen, after we've finished pairing.
 - Perhaps our PairDone was not received. To handle this, we keep
 - a list of recently finished pairings, and re-send PairDone in
 - response to stale PairAcks for them.
 -}
pairAckReceived :: Bool -> Maybe PairingInProgress -> ThreadState -> DaemonStatusHandle -> ScanRemoteMap -> PairMsg -> IO ()
pairAckReceived False _ _ _ _ _ = noop -- not verified
pairAckReceived True Nothing _ _ _ _ = noop -- not in progress
pairAckReceived True (Just pip) st dstatus scanremotes msg = do
	stopSending dstatus pip
	finishedPairing st dstatus scanremotes msg (inProgressSshKeyPair pip)
	startSending dstatus pip $ multicastPairMsg
		(Just 10) (inProgressSecret pip) PairDone (inProgressPairData pip)

{- If we get a verified PairDone, the host has accepted our PairAck, and
 - has paired with us. Stop sending PairAcks, and finish pairing with them.
 -
 - TODO: Should third-party hosts remove their pair request alert when they
 - see a PairDone? How to tell if a PairDone matches with the PairReq 
 - that brought up the alert? Cannot verify it without the secret..
 -}
pairDoneReceived :: Bool -> Maybe PairingInProgress -> ThreadState -> DaemonStatusHandle -> ScanRemoteMap -> PairMsg -> IO ()
pairDoneReceived False _ _ _ _ _ = noop -- not verified
pairDoneReceived True Nothing _ _ _ _ = noop -- not in progress
pairDoneReceived True (Just pip) st dstatus scanremotes msg = do
	stopSending dstatus pip
	finishedPairing st dstatus scanremotes msg (inProgressSshKeyPair pip)
