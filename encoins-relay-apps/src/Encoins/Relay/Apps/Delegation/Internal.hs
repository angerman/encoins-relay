{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TupleSections              #-}

module Encoins.Relay.Apps.Delegation.Internal where

import           Cardano.Api                   (NetworkId, writeFileJSON)
import           Cardano.Server.Utils.Logger   (HasLogger (..), Logger, logMsg, (.<))
import           Control.Exception             (throw)
import           Control.Monad                 (forM, guard, when, mzero, void)
import           Control.Monad.Catch           (MonadCatch, MonadThrow (..))
import           Control.Monad.Except          (MonadError)
import           Control.Monad.IO.Class        (MonadIO (..))
import           Control.Monad.Reader          (MonadReader (ask), ReaderT (..), asks)
import           Control.Monad.Trans.Maybe     (MaybeT (..))
import           Data.Aeson                    (FromJSON (..), ToJSON, genericParseJSON)
import           Data.Aeson.Casing             (aesonPrefix, snakeCase)
import           Data.Function                 (on)
import           Data.Functor                  ((<&>))
import           Data.List                     (sortBy)
import qualified Data.List.NonEmpty            as NonEmpty
import           Data.Map                      (Map)
import qualified Data.Map                      as Map
import           Data.Maybe                    (catMaybes, listToMaybe, mapMaybe)
import           Data.Ord                      (Down (..))
import           Data.Text                     (Text)
import qualified Data.Text                     as T
import           Encoins.Relay.Apps.Internal   (newProgressBar, loadMostRecentFile, formatTime)
import           GHC.Generics                  (Generic)
import           Ledger                        (Address (..), Credential, Datum (..), DatumFromQuery (..), PubKeyHash (..), Slot,
                                                TxId (..), TxOutRef (..))
import           Network.URI                   (isIPv4address, isURI)
import           Plutus.V1.Ledger.Api          (Credential (..), CurrencySymbol, FromData (..), StakingCredential (..), TokenName,
                                                fromBuiltin)
import qualified PlutusAppsExtra.IO.Blockfrost as Bf
import qualified PlutusAppsExtra.IO.Maestro    as Maestro
import           PlutusAppsExtra.Utils.Address (getStakeKey)
import           PlutusAppsExtra.Utils.Maestro (TxDetailsOutput (..), TxDetailsResponse (..))
import           PlutusTx.Builtins             (decodeUtf8)
import           Servant                       (Handler, ServerError, runHandler)
import           System.ProgressBar            (incProgress)
import Control.Applicative ((<|>))
import qualified Data.Time as Time

newtype DelegationM a = DelegationM {unDelegationM :: ReaderT DelegationEnv Servant.Handler a}
    deriving newtype
        ( Functor
        , Applicative
        , Monad
        , MonadIO
        , MonadThrow
        , MonadCatch
        , MonadReader DelegationEnv
        , MonadError Servant.ServerError
        )

runDelegationM :: DelegationEnv -> DelegationM a -> IO a
runDelegationM env = fmap (either throw id) . Servant.runHandler . (`runReaderT` env) . unDelegationM

instance HasLogger DelegationM where
    getLogger = asks dEnvLogger
    getLoggerFilePath = asks dEnvLoggerFp

data DelegationEnv = DelegationEnv
    { dEnvLogger               :: Logger DelegationM
    , dEnvLoggerFp             :: Maybe FilePath
    , dEnvNetworkId            :: NetworkId
    , dEnvHost                 :: Text
    , dEnvPort                 :: Int
    , dEnvDelegationFolder     :: FilePath
    , dEnvFrequency            :: Int
    -- ^ Frequency of search for new delegations in seconds
    , dEnvMaxDelay             :: Int
    -- ^ Maximum permissible synchronization delay in seconds, if exceeded, an error will be thrown
    , dEnvMinTokenNumber       :: Integer
    -- ^ The number of tokens, exceeding which the server gets into the current servers endpoint
    , dEnvRewardTokenThreshold :: Integer
    -- ^ The number of tokens that limits the distribution of rewards
    , dEnvCurrencySymbol       :: CurrencySymbol
    , dEnvTokenName            :: TokenName
    , dEnvCheckSig             :: Bool
    -- ^ There is no signature checks in tests untill cardano-wallet signature fix
    -- https://github.com/cardano-foundation/cardano-wallet/issues/4104
    -- (They are still present outside of tests)
    }

data DelegConfig = DelegConfig
    { cHost                     :: Text
    , cPort                     :: Int
    , cNetworkId                :: NetworkId
    , cDelegationCurrencySymbol :: CurrencySymbol
    , cDelegationTokenName      :: TokenName
    , cDelegationFolder         :: FilePath
    , cFrequency                :: Int
    -- ^ Minimal frequency of search for new delegations in seconds
    , cMaxDelay                 :: Int
    -- ^ Maximum permissible synchronization delay in seconds, if exceeded, an error will be thrown
    , cMinTokenNumber           :: Integer
    -- ^ The number of tokens, exceeding which the server gets into the current servers endpoint
    , cRewardTokenThreshold     :: Integer
    -- ^ The number of tokens that limits the distribution of rewards
    } deriving (Show, Generic)

instance FromJSON DelegConfig where
   parseJSON = genericParseJSON $ aesonPrefix snakeCase

------------------------------------------------------------------ Helpers ------------------------------------------------------------------

data Progress = Progress
    { pLastTxId   :: Maybe TxId
    , pDelgations :: [Delegation]
    } deriving (Show, Generic, FromJSON, ToJSON)

loadPastProgress :: FilePath -> IO (Time.UTCTime, Progress)
loadPastProgress delegFolder =
    loadMostRecentFile delegFolder "delegatorsV2_" >>= maybe mzero pure

updateProgress :: Progress -> DelegationM Progress
updateProgress Progress{..} = do
    DelegationEnv{..} <- ask
    txIds     <- liftIO $ Bf.getAllAssetTxsAfterTxId dEnvNetworkId dEnvCurrencySymbol dEnvTokenName pLastTxId
    pb        <- newProgressBar "Getting delegations" (length txIds)
    newDelegs <- fmap catMaybes $ forM txIds $ \txId -> do
        liftIO $ incProgress pb 1
        findDeleg txId
    logMsg $ "New delegs:" .< newDelegs
    pure $ Progress (listToMaybe txIds <|> pLastTxId) $ removeDuplicates $ pDelgations <> newDelegs

writeResultFile :: FilePath -> Time.UTCTime -> Map Text Integer -> IO ()
writeResultFile delegFolder ct ipsWithBalances =
    let result = Map.map (T.pack . show) ipsWithBalances
    in  void $ writeFileJSON (delegFolder <> "/result_" <> formatTime ct <> ".json") result

findDeleg :: TxId -> DelegationM (Maybe Delegation)
findDeleg txId = runMaybeT $ do
    DelegationEnv{..} <- ask
    TxDetailsResponse{..} <- MaybeT $ liftIO $ Maestro.getTxDetails dEnvNetworkId txId
    MaybeT $ fmap (listToMaybe . catMaybes) $ forM tdrOutputs $ \TxDetailsOutput{..} -> runMaybeT $ do
        stakeKey  <- hoistMaybe $ getStakeKey tdoAddress
        (dh, dfq) <- hoistMaybe tdoDatum
        Datum dat <- case dfq of
            DatumUnknown   -> MaybeT $ liftIO $ Bf.getDatumByHash dEnvNetworkId dh
            DatumInline da -> pure da
            DatumInBody da -> pure da
        ["ENCOINS", "Delegate", skBbs, ipBbs] <- hoistMaybe $ fromBuiltinData dat
        let ipAddr = fromBuiltin $ decodeUtf8 ipBbs
        when dEnvCheckSig $ guard $ PubKeyHash skBbs `elem` tdrAdditionalSigners && isValidIp ipAddr
        pure $ Delegation (addressCredential tdoAddress) stakeKey (TxOutRef tdoTxHash tdoIndex) tdrSlot ipAddr
    where
        hoistMaybe = MaybeT . pure

getIpsWithBalances :: [Delegation] -> DelegationM (Map Text Integer)
getIpsWithBalances delegs = concatIpsWithBalances <$> do
    balances <- getBalances
    pure $ mapMaybe (\Delegation{..} -> Map.lookup delegStakeKey balances <&> (delegIp,)) delegs

getBalances :: DelegationM (Map PubKeyHash Integer)
getBalances = do
    DelegationEnv{..} <- ask
    liftIO $ Maestro.getAccountAddressesHoldingAssets dEnvNetworkId dEnvCurrencySymbol dEnvTokenName

isValidIp :: Text -> Bool
isValidIp txt = or $ [isSimpleURI, isURI, isIPv4address] <&> ($ T.unpack txt)
    where
        isSimpleURI "" = False
        isSimpleURI _  = case T.splitOn "." txt of [_, _] -> True; _ -> False

-- Make map with ips and sum of delegated tokens from list with each delegation ip and token amount
concatIpsWithBalances :: [(Text, Integer)] -> Map Text Integer
concatIpsWithBalances = Map.fromList
                      . map (\xs -> (fst $ NonEmpty.head xs, sum $ snd <$> xs))
                      . NonEmpty.groupBy ((==) `on` fst)
                      . sortBy (compare `on` fst)

data Delegation = Delegation
    { delegCredential :: Credential
    , delegStakeKey   :: PubKeyHash
    , delegTxOutRef   :: TxOutRef
    , delegCreated    :: Slot
    , delegIp         :: Text
    } deriving (Show, Eq, Ord, Generic, FromJSON, ToJSON)

delegAddress :: Delegation -> Address
delegAddress d = Address (delegCredential d) (Just $ StakingHash $ PubKeyCredential $ delegStakeKey d)

lastDelegation :: [Delegation] -> Maybe Delegation
lastDelegation = listToMaybe . sortBy (compare `on` Down . delegCreated)

removeDuplicates :: [Delegation] -> [Delegation]
removeDuplicates = fmap (NonEmpty.head . NonEmpty.sortBy (compare `on` Down . delegCreated))
                 . NonEmpty.groupBy ((==) `on` delegStakeKey)
                 . sortBy (compare `on` delegStakeKey)