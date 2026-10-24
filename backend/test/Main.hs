module Main (main) where

import qualified ProtocolSpec
import qualified DomainDecideSpec
import qualified DomainPropertySpec
import qualified DomainReplaySpec
import qualified ServerSpec
import qualified SessionActorSpec
import qualified SessionE2ESpec
import qualified StoreSpec
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  ProtocolSpec.spec
  DomainReplaySpec.spec
  DomainDecideSpec.spec
  DomainPropertySpec.spec
  StoreSpec.spec
  SessionActorSpec.spec
  ServerSpec.spec
  SessionE2ESpec.spec
