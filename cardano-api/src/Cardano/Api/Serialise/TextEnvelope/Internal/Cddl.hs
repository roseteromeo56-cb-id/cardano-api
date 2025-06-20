{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

-- | Ledger CDDL Serialisation
--
-- TODO: remove references to CDDL as it's meaningless now - everything is aligning with CDDL currently
module Cardano.Api.Serialise.TextEnvelope.Internal.Cddl
  ( TextEnvelopeCddlError (..)
  , FromSomeTypeCDDL (..)
  , cddlTypeToEra

    -- * Reading one of several transaction or

  -- key witness types
  , readFileTextEnvelopeCddlAnyOf
  , deserialiseFromTextEnvelopeCddlAnyOf
  , writeTxFileTextEnvelopeCddl
  , writeTxFileTextEnvelopeCanonicalCddl
  , writeTxWitnessFileTextEnvelopeCddl
  -- Exported for testing
  , deserialiseByronTxCddl
  , serialiseWitnessLedgerCddl
  , deserialiseWitnessLedgerCddl

    -- * Byron tx serialization
  , serializeByronTx
  , writeByronTxFileTextEnvelopeCddl
  )
where

import Cardano.Api.Era.Internal.Eon.ShelleyBasedEra
import Cardano.Api.Error
import Cardano.Api.IO
import Cardano.Api.Pretty
import Cardano.Api.Serialise.Cbor.Canonical
import Cardano.Api.Serialise.TextEnvelope.Internal
  ( TextEnvelope (..)
  , TextEnvelopeDescr (TextEnvelopeDescr)
  , TextEnvelopeError (..)
  , TextEnvelopeType (TextEnvelopeType)
  , deserialiseFromTextEnvelope
  , legacyComparison
  , serialiseTextEnvelope
  , serialiseToTextEnvelope
  )
import Cardano.Api.Tx.Internal.Sign

import Cardano.Chain.UTxO qualified as Byron
import Cardano.Ledger.Binary (DecoderError)
import Cardano.Ledger.Binary qualified as CBOR

import Control.Monad.Trans.Except.Extra
  ( firstExceptT
  , hoistEither
  , newExceptT
  , runExceptT
  )
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Data (Data)
import Data.Either.Combinators (mapLeft)
import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as T

-- Why have we gone this route? The serialization format of `TxBody era`
-- differs from the CDDL. We serialize to an intermediate type in order to simplify
-- the specification of Plutus scripts and to avoid users having to think about
-- and construct redeemer pointers. However it turns out we can still serialize to
-- the ledger's CDDL format and maintain the convenient script witness specification
-- that the cli commands build and build-raw expose.
--
-- The long term plan is to have all relevant outputs from the cli to adhere to
-- the ledger's CDDL spec. Modifying the existing TextEnvelope machinery to encompass
-- this would result in a lot of unnecessary changes where the serialization
-- already defaults to the CDDL spec. In order to reduce the number of changes, and to
-- ease removal of the non-CDDL spec serialization, we have opted to create a separate
-- data type to encompass this in the interim.

data TextEnvelopeCddlError
  = TextEnvelopeCddlErrCBORDecodingError DecoderError
  | TextEnvelopeCddlAesonDecodeError FilePath String
  | TextEnvelopeCddlUnknownKeyWitness
  | TextEnvelopeCddlTypeError
      [Text]
      -- ^ Expected types
      Text
      -- ^ Actual types
  | TextEnvelopeCddlErrUnknownType Text
  | TextEnvelopeCddlErrByronKeyWitnessUnsupported
  deriving (Show, Eq, Data)

textEnvelopeErrorToTextEnvelopeCddlError :: TextEnvelopeError -> TextEnvelopeCddlError
textEnvelopeErrorToTextEnvelopeCddlError = \case
  TextEnvelopeTypeError expectedTypes actualType ->
    TextEnvelopeCddlTypeError
      (map (T.pack . show) expectedTypes)
      (T.pack $ show actualType)
  TextEnvelopeDecodeError decoderError -> TextEnvelopeCddlErrCBORDecodingError decoderError
  TextEnvelopeAesonDecodeError errorString -> TextEnvelopeCddlAesonDecodeError "" errorString

instance Error TextEnvelopeCddlError where
  prettyError = \case
    TextEnvelopeCddlErrCBORDecodingError decoderError ->
      "TextEnvelopeCDDL CBOR decoding error: " <> pshow decoderError
    TextEnvelopeCddlAesonDecodeError fp aesonErr ->
      mconcat
        [ "Could not JSON decode TextEnvelopeCddl file at: " <> pretty fp
        , " Error: " <> pretty aesonErr
        ]
    TextEnvelopeCddlUnknownKeyWitness ->
      "Unknown key witness specified"
    TextEnvelopeCddlTypeError expTypes actType ->
      mconcat
        [ "TextEnvelopeCddl type error: "
        , " Expected one of: "
        , mconcat $ List.intersperse ", " (map pretty expTypes)
        , " Actual: " <> pretty actType
        ]
    TextEnvelopeCddlErrUnknownType unknownType ->
      "Unknown TextEnvelopeCddl type: " <> pretty unknownType
    TextEnvelopeCddlErrByronKeyWitnessUnsupported ->
      "TextEnvelopeCddl error: Byron key witnesses are currently unsupported."

writeByronTxFileTextEnvelopeCddl
  :: File content Out
  -> Byron.ATxAux ByteString
  -> IO (Either (FileError ()) ())
writeByronTxFileTextEnvelopeCddl path =
  writeLazyByteStringFile path
    . serialiseTextEnvelope
    . serializeByronTx

serializeByronTx :: Byron.ATxAux ByteString -> TextEnvelope
serializeByronTx tx =
  TextEnvelope
    { teType = "Tx ByronEra"
    , teDescription = "Ledger Cddl Format"
    , teRawCBOR = CBOR.recoverBytes tx
    }

deserialiseByronTxCddl :: TextEnvelope -> Either TextEnvelopeCddlError (Byron.ATxAux ByteString)
deserialiseByronTxCddl tec =
  first TextEnvelopeCddlErrCBORDecodingError $
    CBOR.decodeFullAnnotatedBytes
      CBOR.byronProtVer
      "Byron Tx"
      CBOR.decCBOR
      (LBS.fromStrict $ teRawCBOR tec)

serialiseWitnessLedgerCddl :: forall era. ShelleyBasedEra era -> KeyWitness era -> TextEnvelope
serialiseWitnessLedgerCddl sbe kw =
  shelleyBasedEraConstraints sbe $
    serialiseToTextEnvelope (Just $ TextEnvelopeDescr desc) kw
 where
  desc :: String
  desc = shelleyBasedEraConstraints sbe $ case kw of
    ShelleyBootstrapWitness{} -> "Key BootstrapWitness ShelleyEra"
    ShelleyKeyWitness{} -> "Key Witness ShelleyEra"

deserialiseWitnessLedgerCddl
  :: forall era
   . ShelleyBasedEra era
  -> TextEnvelope
  -> Either TextEnvelopeCddlError (KeyWitness era)
deserialiseWitnessLedgerCddl sbe te =
  shelleyBasedEraConstraints sbe $
    legacyDecoding te $
      mapLeft textEnvelopeErrorToTextEnvelopeCddlError $
        deserialiseFromTextEnvelope te
 where
  -- This wrapper ensures that we can still decode the key witness
  -- that were serialized before we migrated to using 'serialiseToTextEnvelope'
  legacyDecoding
    :: TextEnvelope
    -> Either TextEnvelopeCddlError (KeyWitness era)
    -> Either TextEnvelopeCddlError (KeyWitness era)
  legacyDecoding TextEnvelope{teDescription, teRawCBOR} (Left (TextEnvelopeCddlErrCBORDecodingError _)) =
    case teDescription of
      "Key BootstrapWitness ShelleyEra" -> do
        w <-
          first TextEnvelopeCddlErrCBORDecodingError $
            CBOR.decodeFullAnnotator
              (eraProtVerLow sbe)
              "Shelley Witness"
              CBOR.decCBOR
              (LBS.fromStrict teRawCBOR)
        Right $ ShelleyBootstrapWitness sbe w
      "Key Witness ShelleyEra" -> do
        w <-
          first TextEnvelopeCddlErrCBORDecodingError $
            CBOR.decodeFullAnnotator
              (eraProtVerLow sbe)
              "Shelley Witness"
              CBOR.decCBOR
              (LBS.fromStrict teRawCBOR)
        Right $ ShelleyKeyWitness sbe w
      _ -> Left TextEnvelopeCddlUnknownKeyWitness
  legacyDecoding _ v = v

writeTxFileTextEnvelopeCddl
  :: ShelleyBasedEra era
  -> File content Out
  -> Tx era
  -> IO (Either (FileError ()) ())
writeTxFileTextEnvelopeCddl sbe path =
  writeLazyByteStringFile path
    . serialiseTextEnvelope
    . serialiseTxToTextEnvelope sbe

-- | Write transaction in the text envelope format. The CBOR will be in canonical format according
-- to RFC 7049. It is also a requirement of CIP-21, which is not fully implemented.
--
-- 1. RFC 7049: https://datatracker.ietf.org/doc/html/rfc7049#section-3.9
-- 2. CIP-21: https://github.com/cardano-foundation/CIPs/blob/master/CIP-0021/README.md#canonical-cbor-serialization-format
writeTxFileTextEnvelopeCanonicalCddl
  :: ShelleyBasedEra era
  -> File content Out
  -> Tx era
  -> IO (Either (FileError ()) ())
writeTxFileTextEnvelopeCanonicalCddl sbe path =
  writeLazyByteStringFile path
    . serialiseTextEnvelope
    . canonicaliseTextEnvelopeCbor
    . serialiseTxToTextEnvelope sbe
 where
  canonicaliseTextEnvelopeCbor :: TextEnvelope -> TextEnvelope
  canonicaliseTextEnvelopeCbor te = do
    let canonicalisedTxBs =
          either
            ( \err ->
                error $
                  "writeTxFileTextEnvelopeCanonicalCddl: Impossible - deserialisation of just serialised bytes failed "
                    <> show err
            )
            id
            . canonicaliseCborBs
            $ teRawCBOR te
    te{teRawCBOR = canonicalisedTxBs}

serialiseTxToTextEnvelope :: ShelleyBasedEra era -> Tx era -> TextEnvelope
serialiseTxToTextEnvelope era' tx' =
  shelleyBasedEraConstraints era' $ do
    serialiseToTextEnvelope (Just "Ledger Cddl Format") tx'

writeTxWitnessFileTextEnvelopeCddl
  :: ShelleyBasedEra era
  -> File () Out
  -> KeyWitness era
  -> IO (Either (FileError ()) ())
writeTxWitnessFileTextEnvelopeCddl sbe path =
  writeLazyByteStringFile path
    . serialiseTextEnvelope
    . serialiseWitnessLedgerCddl sbe

-- | This GADT allows us to deserialise a tx or key witness without
-- having to provide the era.
data FromSomeTypeCDDL c b where
  FromCDDLTx
    :: Text
    -- ^ CDDL type that we want
    -> (InAnyShelleyBasedEra Tx -> b)
    -> FromSomeTypeCDDL TextEnvelope b
  FromCDDLWitness
    :: Text
    -- ^ CDDL type that we want
    -> (InAnyShelleyBasedEra KeyWitness -> b)
    -> FromSomeTypeCDDL TextEnvelope b

deserialiseFromTextEnvelopeCddlAnyOf
  :: [FromSomeTypeCDDL TextEnvelope b]
  -> TextEnvelope
  -> Either TextEnvelopeCddlError b
deserialiseFromTextEnvelopeCddlAnyOf types teCddl =
  case List.find matching types of
    Nothing ->
      Left (TextEnvelopeCddlTypeError expectedTypes actualType)
    Just (FromCDDLTx ttoken f) -> do
      AnyShelleyBasedEra era <- cddlTypeToEra ttoken
      f . InAnyShelleyBasedEra era
        <$> mapLeft textEnvelopeErrorToTextEnvelopeCddlError (deserialiseTxLedgerCddl era teCddl)
    Just (FromCDDLWitness ttoken f) -> do
      AnyShelleyBasedEra era <- cddlTypeToEra ttoken
      f . InAnyShelleyBasedEra era <$> deserialiseWitnessLedgerCddl era teCddl
 where
  actualType :: Text
  actualType = T.pack $ show $ teType teCddl

  expectedTypes :: [Text]
  expectedTypes = [typ | FromCDDLTx typ _f <- types]

  matching :: FromSomeTypeCDDL TextEnvelope b -> Bool
  matching (FromCDDLTx ttoken _f) = TextEnvelopeType (T.unpack ttoken) `legacyComparison` teType teCddl
  matching (FromCDDLWitness ttoken _f) = TextEnvelopeType (T.unpack ttoken) `legacyComparison` teType teCddl

  deserialiseTxLedgerCddl
    :: forall era
     . ShelleyBasedEra era
    -> TextEnvelope
    -> Either TextEnvelopeError (Tx era)
  deserialiseTxLedgerCddl era = shelleyBasedEraConstraints era deserialiseFromTextEnvelope

-- Parse the text into types because this will increase code readability and
-- will make it easier to keep track of the different Cddl descriptions via
-- a single sum data type.
cddlTypeToEra :: Text -> Either TextEnvelopeCddlError AnyShelleyBasedEra
cddlTypeToEra =
  \case
    "TxSignedShelley" -> return $ AnyShelleyBasedEra ShelleyBasedEraShelley
    "Tx AllegraEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraAllegra
    "Tx MaryEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraMary
    "Tx AlonzoEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraAlonzo
    "Tx BabbageEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraBabbage
    "Tx ConwayEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraConway
    "Witnessed Tx ShelleyEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraShelley
    "Witnessed Tx AllegraEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraAllegra
    "Witnessed Tx MaryEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraMary
    "Witnessed Tx AlonzoEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraAlonzo
    "Witnessed Tx BabbageEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraBabbage
    "Witnessed Tx ConwayEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraConway
    "Unwitnessed Tx ShelleyEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraShelley
    "Unwitnessed Tx AllegraEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraAllegra
    "Unwitnessed Tx MaryEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraMary
    "Unwitnessed Tx AlonzoEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraAlonzo
    "Unwitnessed Tx BabbageEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraBabbage
    "Unwitnessed Tx ConwayEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraConway
    "TxWitness ShelleyEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraShelley
    "TxWitness AllegraEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraAllegra
    "TxWitness MaryEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraMary
    "TxWitness AlonzoEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraAlonzo
    "TxWitness BabbageEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraBabbage
    "TxWitness ConwayEra" -> return $ AnyShelleyBasedEra ShelleyBasedEraConway
    unknownCddlType -> Left $ TextEnvelopeCddlErrUnknownType unknownCddlType

readFileTextEnvelopeCddlAnyOf
  :: [FromSomeTypeCDDL TextEnvelope b]
  -> FilePath
  -> IO (Either (FileError TextEnvelopeCddlError) b)
readFileTextEnvelopeCddlAnyOf types path =
  runExceptT $ do
    te <- newExceptT $ readTextEnvelopeCddlFromFile path
    firstExceptT (FileError path) $ hoistEither $ do
      deserialiseFromTextEnvelopeCddlAnyOf types te

readTextEnvelopeCddlFromFile
  :: FilePath
  -> IO (Either (FileError TextEnvelopeCddlError) TextEnvelope)
readTextEnvelopeCddlFromFile path =
  runExceptT $ do
    bs <- fileIOExceptT path readFileBlocking
    firstExceptT (FileError path . TextEnvelopeCddlAesonDecodeError path)
      . hoistEither
      $ Aeson.eitherDecodeStrict' bs
