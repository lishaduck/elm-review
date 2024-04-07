module Review.FilePattern exposing (FilePattern, exclude, excludeFolder, include, match)

import Glob exposing (Glob)
import Review.Rule exposing (globalError)


type FilePattern
    = Include Glob
    | Exclude Glob
    | ExcludeFolder Glob
    | InvalidGlob String


include : String -> FilePattern
include globStr =
    case Glob.fromString globStr of
        Ok glob ->
            Include glob

        Err _ ->
            InvalidGlob globStr


exclude : String -> FilePattern
exclude globStr =
    case Glob.fromString globStr of
        Ok glob ->
            Exclude glob

        Err _ ->
            InvalidGlob globStr


excludeFolder : String -> FilePattern
excludeFolder globStr =
    case Glob.fromString (toFolder globStr) of
        Ok glob ->
            ExcludeFolder glob

        Err _ ->
            InvalidGlob globStr


toFolder : String -> String
toFolder globStr =
    if String.endsWith "/" globStr then
        globStr ++ "**/*"

    else
        globStr ++ "/**/*"


match : List FilePattern -> String -> Bool
match filePatterns str =
    matchHelp filePatterns str False


matchHelp : List FilePattern -> String -> Bool -> Bool
matchHelp filePatterns str acc =
    case filePatterns of
        [] ->
            acc

        (Include glob) :: rest ->
            matchHelp rest str (acc || Glob.match glob str)

        (Exclude glob) :: rest ->
            matchHelp rest str (acc && not (Glob.match glob str))

        (ExcludeFolder glob) :: rest ->
            if Glob.match glob str then
                False

            else
                matchHelp rest str acc

        _ ->
            False
