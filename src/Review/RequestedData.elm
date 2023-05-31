module Review.RequestedData exposing (RequestedData(..), combine, combineJust, none)


type RequestedData
    = RequestedData
        { moduleNameLookupTable : Bool
        , sourceCodeExtractor : Bool
        , ignoredFiles : Bool
        , files : List String
        }


none : RequestedData
none =
    RequestedData
        { moduleNameLookupTable = False
        , sourceCodeExtractor = False
        , ignoredFiles = False
        , files = []
        }


combine : Maybe RequestedData -> Maybe RequestedData -> RequestedData
combine maybeA maybeB =
    case maybeA of
        Nothing ->
            Maybe.withDefault none maybeB

        Just a ->
            case maybeB of
                Just b ->
                    combineJust a b

                Nothing ->
                    a


combineJust : RequestedData -> RequestedData -> RequestedData
combineJust (RequestedData a) (RequestedData b) =
    RequestedData
        { moduleNameLookupTable = a.moduleNameLookupTable || b.moduleNameLookupTable
        , sourceCodeExtractor = a.sourceCodeExtractor || b.sourceCodeExtractor
        , ignoredFiles = a.ignoredFiles || b.ignoredFiles
        , files = a.files ++ b.files
        }
