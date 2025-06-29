{-# LANGUAGE TypeApplications #-}

module Test.Cardano.Api.Eras
  ( tests
  )
where

import Cardano.Api

import Data.Aeson (decode, encode)

import Hedgehog (Property, forAll, property, (===))
import Hedgehog qualified as H
import Hedgehog.Gen qualified as Gen
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

--------------------------------------------------------------------------------
-- Bounded instances

prop_maxBound_CardanoMatchesShelley :: Property
prop_maxBound_CardanoMatchesShelley = property $ do
  AnyCardanoEra era <- forAll $ Gen.element [maxBound]
  AnyShelleyBasedEra sbe <- forAll $ Gen.element [maxBound]

  fromEnum (anyCardanoEra era) === fromEnum (anyCardanoEra (toCardanoEra sbe))

--------------------------------------------------------------------------------
-- Aeson instances

prop_roundtrip_JSON_Shelley :: Property
prop_roundtrip_JSON_Shelley = property $ do
  anySbe <- forAll $ Gen.element $ id @[AnyShelleyBasedEra] [minBound .. maxBound]

  H.tripping anySbe encode decode

prop_roundtrip_JSON_Cardano :: Property
prop_roundtrip_JSON_Cardano = property $ do
  anyEra <- forAll $ Gen.element $ id @[AnyCardanoEra] [minBound .. maxBound]

  H.tripping anyEra encode decode

prop_toJSON_CardanoMatchesShelley :: Property
prop_toJSON_CardanoMatchesShelley = property $ do
  AnyShelleyBasedEra sbe <- forAll $ Gen.element [minBound .. maxBound]

  toJSON (AnyShelleyBasedEra sbe) === toJSON (anyCardanoEra (toCardanoEra sbe))

tests :: TestTree
tests =
  testGroup
    "Test.Cardano.Api.Json"
    [ testProperty "maxBound cardano matches shelley" prop_maxBound_CardanoMatchesShelley
    , testProperty "roundtrip JSON shelley" prop_roundtrip_JSON_Shelley
    , testProperty "roundtrip JSON cardano" prop_roundtrip_JSON_Cardano
    , testProperty "toJSON cardano matches shelley" prop_toJSON_CardanoMatchesShelley
    ]
