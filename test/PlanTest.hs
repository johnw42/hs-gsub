{-# LANGUAGE TemplateHaskell #-}
module PlanTest (tests) where

import Plan

import Control.Applicative ((<$>), (<*>))
import Control.Monad
import qualified Data.ByteString as B
import Data.Char (isHexDigit)
import Data.Either
import Data.List
import Data.Maybe
import System.IO (stdout)
import System.Random
import Test.Framework (testGroup)
import Test.Framework.Providers.QuickCheck2 (testProperty)
import Test.QuickCheck

type FlagPart = String
type PosArg = String

instance Arbitrary Plan where
    arbitrary = makePlan 
        <$> arbitrary `suchThat` ('\n' `notElem`) `suchThat` (not . null)
        <*> arbitrary `suchThat` ('\n' `notElem`)
        <*> arbitrary
        <*> elements [RunMode, DryRunMode, DiffMode, UndoMode]
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary

prop_toHexString1 s = length (toHexString (B.pack s)) == 2 * length s
prop_toHexString2 s = all isHexDigit (toHexString (B.pack s))

-- Generator for arbitrary positional arguments.
arbPosArg :: Gen PosArg
arbPosArg = arbitrary `suchThat` (not . ("-" `isPrefixOf`))

-- Generator for an arbitrary list of positional arguments.
arbPosArgList :: Gen [PosArg]
arbPosArgList = liftM2 (++) (vectorOf 3 arbPosArg) (listOf arbPosArg)

modeFlags = ["--diff", "-D", "--no-modify", "-N", "-u", "--undo"]
otherFlags = ["-F", "--fixed-strings"]
shortFlagsWithArg = ["-i"]
longFlagsWithArg = ["--backup-suffix"]

-- Generator for arbitrary flags.
arbFlag :: Gen [FlagPart]
arbFlag = do
    modeFlag <- elements modeFlags
    otherFlag <- elements otherFlags
    someChar <- arbitrary
    flagArg <- arbitrary
    shortFlag <- elements shortFlagsWithArg
    longFlag <- elements longFlagsWithArg
    frequency
        [ (2, return [modeFlag])
        , (2, return [otherFlag])
        , (1, return [shortFlag ++ (someChar:flagArg)])
        , (1, return [shortFlag, flagArg])
        , (1, return [longFlag ++ "=" ++ flagArg])
        , (1, return [longFlag, flagArg])
        ]

prop_arbFlag_length :: Property
prop_arbFlag_length =
    forAll arbFlag (\flag -> length flag `elem` [1..2])

prop_arbFlag_dash =
    forAll arbFlag (\flag -> "-" `isPrefixOf` head flag)

-- Arbitrary list of flags to apply at one time.
arbFlagList :: Gen [[FlagPart]]
arbFlagList = resize 3 $ listOf arbFlag

-- Randomly insert flags into a list of positional arguments.
withFlags :: [PosArg] -> [[FlagPart]] -> Gen [String]
withFlags posArgs flags = concat `liftM` foldM insertFlag initSegments flags
    where
        initSegments = map (:[]) posArgs

        insertFlag :: [[String]] -> [FlagPart] -> Gen [[String]]
        insertFlag segments flag = do
            i <- choose (0, length segments)
            let (before, after) = splitAt i segments
            return $ before ++ [flag] ++ after


-- Arbitrary complete argument list.
arbFullArgList :: Gen [String]
arbFullArgList = do
     (FullArgList _ _ args) <- arbFullArgList'
     return args

data FullArgList = FullArgList
    [String]    -- Positional arguments.
    [[String]]  -- Flags.
    [String]    -- Combined argument list.
    deriving Show

-- Arbitrary complete argument list with separate flags and positional args.
arbFullArgList' :: Gen FullArgList
arbFullArgList' = do
    posArgs <- arbPosArgList
    flags <- arbFlagList
    args <- posArgs `withFlags` flags
    return $ FullArgList posArgs flags args
    
-- Test with too few arguments.
prop_parseArgs_notEnough name =
    forAll (resize 2 $ listOf arbPosArg) $ \posArgs ->
    forAll arbFlagList $ \flags ->
    forAll (posArgs `withFlags` flags) $ \args ->
    conjoin
        [ isLeft (parseArgs name posArgs)
        , isLeft (parseArgs name args)
        ]

-- Test with no flags.
prop_parseArgs_noFlags name =
    forAll arbPosArgList $ \(args@(p:r:fs)) ->
    case parseArgs name args of
        Right plan -> conjoin
            [ filesToProcess plan == fs
            , patternString plan == p
            , replacementString plan == r
            ]
        Left _ -> property False

-- Test with valid flags.
prop_parseArgs_withFlags name =
    forAll arbFullArgList' $ \(FullArgList (p:r:fs) flags args) ->
    case parseArgs name args of
        Right plan -> conjoin
            [ filesToProcess plan == fs
            , patternString plan == p
            , replacementString plan == r
            ]
        Left _ -> discard

prop_parseArgs_withDiff name  =
    forAll arbFullArgList $ \args ->
    ("-D" `elem` args || "--diff" `elem` args) ==> case parseArgs name args of
        Left _ -> discard
        Right plan -> planMode plan == DiffMode

prop_parseArgs_withDryRun name =
    forAll arbFullArgList $ \args ->
    ("-N" `elem` args || "--no-modify" `elem` args) ==> case parseArgs name args of
        Left _ -> discard
        Right plan -> planMode plan == DryRunMode

prop_parseArgs_withUndo name =
    forAll arbFullArgList $ \args ->
    ("-u" `elem` args || "--undo" `elem` args) ==> case parseArgs name args of
        Left _ -> discard
        Right plan -> planMode plan == UndoMode

prop_parseArgs_withDefaultMode name =
    forAll arbFullArgList $ \args ->
    not (any (`elem` modeFlags) args) ==> case parseArgs name args of
        Left _ -> discard
        Right plan -> planMode plan == RunMode

tests = testGroup "Plan" [
  testProperty "toHexString1" prop_toHexString1,
  testProperty "arbFlag_length" prop_arbFlag_length,
  testProperty "arbFlag_dash" prop_arbFlag_dash,
  testProperty "parseArgs_notEnough" prop_parseArgs_notEnough,
  testProperty "parseArgs_noFlags" prop_parseArgs_noFlags,
  testProperty "parseArgs_withFlags" prop_parseArgs_withFlags,
  testProperty "parseArgs_withDiff" prop_parseArgs_withDiff,
  testProperty "parseArgs_withDryRun" prop_parseArgs_withDryRun,
  testProperty "parseArgs_withUndo" prop_parseArgs_withUndo,
  testProperty "parseArgs_withDefaultMode" prop_parseArgs_withDefaultMode
  ]