{-# LANGUAGE DataKinds     #-}
{-# LANGUAGE PolyKinds     #-}
{-# LANGUAGE TypeFamilies  #-}
{-# LANGUAGE TypeOperators #-}

module Encoins.Relay.Server.Api where

import qualified CSL
import           Cardano.Server.Endpoints.Tx.Submit (SubmitTxReqBody)
import           Cardano.Server.Error               (Throws)
import           Cardano.Server.Error.Servant       (Throwing)
import           Data.Text                          (Text)
import           Data.Type.Equality                 ((:~:) (..))
import           Encoins.Relay.Server.Server        (EncoinsApi, InputOfEncoinsApi)
import           Encoins.Relay.Server.Status        (EncoinsStatusReqBody, EncoinsStatusResult)
import           Encoins.Relay.Server.Version       (ServerVersion)
import           Servant                            (Get, Post, JSON, NoContent, ReqBody, type (:<|>), type (:>))

type Api
    =    "ping"
      :> Get '[JSON] NoContent

    :<|> "utxos"
      :> ReqBody '[JSON] Text
      :> Get '[JSON] CSL.TransactionUnspentOutputs

    :<|> "newTx"
      :> ReqBody '[JSON] (InputOfEncoinsApi, CSL.TransactionInputs)
      :> Post '[JSON] (Text, Text)

    :<|> "submitTx"
      :> ReqBody '[JSON] SubmitTxReqBody
      :> Post '[JSON] NoContent

    :<|> "serverTx"
      :> ReqBody '[JSON] (InputOfEncoinsApi, CSL.TransactionInputs)
      :> Post '[JSON] NoContent

    :<|> "status"
      :> ReqBody '[JSON] EncoinsStatusReqBody
      :> Post '[JSON] EncoinsStatusResult

    :<|> "version"
      :> Get '[JSON] ServerVersion

thisApiIsActual :: Api :~: EraseErrors EncoinsApi
thisApiIsActual = Refl

type family EraseErrors a where
    EraseErrors (a        :<|> b) = EraseErrors a :<|> EraseErrors b
    EraseErrors (Throws   _ :> b) = EraseErrors b
    EraseErrors (Throwing _ :> b) = EraseErrors b
    EraseErrors (a          :> b) = a :> EraseErrors b
    EraseErrors  a                = a