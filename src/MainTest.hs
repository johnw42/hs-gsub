module MainTest (test) where

import Main
import Plan

import Control.Monad
import Control.Monad.Random
import Data.Either
import Data.List
import Data.Maybe
import System.IO (stdout)
import Test.QuickCheck

import TestUtils

type FlagPart = String
type PosArg = String

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
        [ case parseArgs name posArgs of
            Left error -> counterexample error $ property $ error == name ++ ": not enough arguments\n"
            Right _ -> property False
        , property $ isLeft (parseArgs name args)
        ]

-- Test with no flags.
prop_parseArgs_noFlags name =
    forAll arbPosArgList $ \(args@(pattern:replacement:files)) ->
    parseArgs name args == Right (defaultPlan pattern replacement files)

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

-- Test that firstJust works.
prop_firstJust_empty = once $ isNothing $ firstJust []
prop_firstJust_allNothing (Positive (Small n)) =
    isNothing $ firstJust $ replicate n Nothing
prop_firstJust_typical (NonEmpty items) =
    case firstJust items of
        Nothing -> all isNothing items
        Just x -> Just x == head (dropWhile isNothing items)

return []
test = $forAllProperties quickCheckProp
