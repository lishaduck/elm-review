module NoExtraBooleanComparisonTest exposing (all)

import Lint.Rule.NoExtraBooleanComparison exposing (rule)
import Lint.Test2 exposing (LintResult)
import Test exposing (Test, describe, test)


testRule : String -> LintResult
testRule string =
    "module A exposing (..)\n\n"
        ++ string
        |> Lint.Test2.run rule


tests : List Test
tests =
    [ test "should not report condition without an operator" <|
        \() ->
            testRule "a = if n then 1 else 2"
                |> Lint.Test2.expectNoErrors
    , test "should not report condition with integer operators" <|
        \() ->
            testRule """
a = if n < 1 then 1 else 2
b = if n <= 1 then 1 else 2
c = if n > 1 then 1 else 2
d = if n >= 1 then 1 else 2
"""
                |> Lint.Test2.expectNoErrors
    , test "should not report condition using `not`" <|
        \() ->
            testRule "a = if not n then 1 else 2"
                |> Lint.Test2.expectNoErrors
    , test "should report condition with `expr == True`" <|
        \() ->
            testRule "a = if b == True then 1 else 2"
                |> Lint.Test2.expectErrors
                    [ Lint.Test2.error
                        { message = "Unnecessary comparison with `True`"
                        , under = " True "
                        }
                    ]
    , test "should report condition with `True == expr`" <|
        \() ->
            testRule "a = if True == b then 1 else 2"
                |> Lint.Test2.expectErrors
                    [ Lint.Test2.error
                        { message = "Unnecessary comparison with `True`"
                        , under = " True "
                        }
                    ]
    , test "should report condition with `expr == False`" <|
        \() ->
            testRule "a = if b == False then 1 else 2"
                |> Lint.Test2.expectErrors
                    [ Lint.Test2.error
                        { message = "Unnecessary comparison with `False`"
                        , under = " False "
                        }
                    ]
    , test "should report condition with `False == expr`" <|
        \() ->
            testRule "a = if False == b then 1 else 2"
                |> Lint.Test2.expectErrors
                    [ Lint.Test2.error
                        { message = "Unnecessary comparison with `False`"
                        , under = " False "
                        }
                    ]
    , test "should report condition with `expr /= True`" <|
        \() ->
            testRule "a = if b /= True then 1 else 2"
                |> Lint.Test2.expectErrors
                    [ Lint.Test2.error
                        { message = "Unnecessary comparison with `True`"
                        , under = " True "
                        }
                    ]
    , test "should report condition with `True /= expr`" <|
        \() ->
            testRule "a = if True /= b then 1 else 2"
                |> Lint.Test2.expectErrors
                    [ Lint.Test2.error
                        { message = "Unnecessary comparison with `True`"
                        , under = " True "
                        }
                    ]
    , test "should report condition with `expr /= False`" <|
        \() ->
            testRule "a = if b /= False then 1 else 2"
                |> Lint.Test2.expectErrors
                    [ Lint.Test2.error
                        { message = "Unnecessary comparison with `False`"
                        , under = " False "
                        }
                    ]
    , test "should report condition with `False /= expr`" <|
        \() ->
            testRule "a = if False /= b then 1 else 2"
                |> Lint.Test2.expectErrors
                    [ Lint.Test2.error
                        { message = "Unnecessary comparison with `False`"
                        , under = " False "
                        }
                    ]
    ]


all : Test
all =
    describe "NoExtraBooleanComparison" tests
