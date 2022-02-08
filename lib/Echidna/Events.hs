{-# LANGUAGE ImplicitParams #-}

module Echidna.Events where

import Data.ByteString.Lazy (fromStrict)
import Data.Tree        (flatten)
import Data.Tree.Zipper (fromForest, TreePos, Empty)
import Data.Text        (pack, Text)
import Data.Maybe       (listToMaybe)
import Control.Lens
import EVM
import EVM.ABI      (Event(..), Indexed(..), decodeAbiValue, AbiType(AbiUIntType))
import EVM.Concrete (wordValue)
import EVM.Dapp
import EVM.Format   (showValues, showError, contractNamePart)
import EVM.Types    (W256, maybeLitWord)
import EVM.Solidity (contractName)

import qualified Data.Map as M
import qualified Data.ByteString as BS

type EventMap = M.Map W256 Event
type Events = [Text]

emptyEvents :: TreePos Empty a
emptyEvents = fromForest []

maybeContractNameFromCodeHash :: (?context :: DappContext) => EVM.Types.W256 -> Maybe Text
maybeContractNameFromCodeHash codeHash = fmap contractToName maybeContract
  where maybeContract = preview (contextInfo . dappSolcByHash . ix codeHash . _2) ?context
        contractToName = view (contractName . to contractNamePart)

extractEvents :: DappInfo -> EventMap -> VM -> Events
extractEvents dappInfo' _ vm =
  let eventMap = dappInfo' ^. dappEventMap
      forest = traceForest vm
      showTrace trace =
        let ?context = DappContext { _contextInfo = dappInfo', _contextEnv = vm ^?! EVM.env . EVM.contracts } in
        let codehash' = trace ^. traceContract . codehash
            maybeContractName = maybeContractNameFromCodeHash codehash'
        in
        case trace ^. traceData of
          EventTrace (Log addr bytes topics) ->
            case maybeLitWord =<< listToMaybe topics of
              Nothing   -> []
              Just word -> case M.lookup (wordValue word) eventMap of
                             Just (Event name _ types) ->
                               -- TODO this is where indexed types are filtered out
                               -- they are filtered out for a reason as they only contain
                               -- the topic hash which is printed super verbose by dapptools
                               [name <>
                                showValues [t | (t, NotIndexed) <- types] bytes <>
                                pack " from: " <>
                                maybe mempty (\ x -> x <> pack "@") maybeContractName <>
                                pack (show addr)]
                             Nothing -> [pack $ show word]
          ErrorTrace e ->
            case e of
              Revert out -> ["merror " <> "Revert " <> showError out <> maybe mempty (\ x -> pack " from: " <> x) maybeContractName]
              _ -> ["merror " <> pack (show e)]
          
          _ -> []
  in decodeRevert vm ++ concat (concatMap flatten $ fmap (fmap showTrace) forest)


decodeRevert :: VM -> Events
decodeRevert vm = 
  case vm ^. result of
    Just (VMFailure (Revert bs)) -> decodeRevertMsg bs
    _                            -> [] 

decodeRevertMsg :: BS.ByteString -> Events 
decodeRevertMsg bs = case BS.splitAt 4 bs of
                          --"\x08\xc3\x79\xa0" -> Just $ "Error(" ++ (show $ decodeAbiValue AbiStringType (fromStrict $ BS.drop 4 bs)) ++ ")"
                          ("\x4e\x48\x7b\x71",d) -> ["Panic(" <> (pack . show $ decodeAbiValue (AbiUIntType 256) (fromStrict d)) <> ")"]
                          _                      -> []
