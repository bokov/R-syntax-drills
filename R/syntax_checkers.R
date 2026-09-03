# Syntax parsing and call inspection -----------------------------------------

# Helpers for checking whether submitted R code uses a requested syntax form.
# Most checks inspect parsed R code. uses_token() is available for syntax that
# R normalizes while parsing (notably the native pipe).

#' Parse submitted R code without propagating syntax errors
#'
#' Converts student code to an R expression for structural syntax checks and
#' returns an empty expression when parsing fails, allowing grading code to
#' report the submission failure instead of these helpers throwing first.
#'
#' @param code Character string containing submitted R code.
#' @return A parsed R expression, or `expression()` after a parse error.
#' @details Called directly by `uses_call()` and `call_has_named_arg()`, and by
#'   current vector-question check chunks. It has no within-repo function
#'   dependencies.
parse_student_code <- function(code) {
  tryCatch(parse(text = code), error = function(e) expression())
}

#' Return the name at the head of an R call
#'
#' Identifies the function or operator invoked by a parsed call, including the
#' function name in namespace-qualified calls such as `pkg::fun()`.
#'
#' @param x Parsed R object to inspect.
#' @return The call-head name as character, or `NA_character_` when `x` is not a
#'   recognized call form.
#' @details Called by `uses_call()` and `call_has_named_arg()`, and directly by
#'   current vector-question check chunks. It has no within-repo function
#'   dependencies.
call_head <- function(x) {
  if (!is.call(x)) return(NA_character_)
  head <- x[[1]]
  if (is.symbol(head)) return(as.character(head))
  if (is.call(head) && identical(as.character(head[[1]]), "::")) {
    return(as.character(head[[3]]))
  }
  NA_character_
}

#' Collect every call in a parsed R expression
#'
#' Recursively traverses an expression or call tree in encounter order and
#' returns the calls so question checks can inspect nested operations as well as
#' the top-level expression.
#'
#' @param x Parsed R expression, call, or other R object.
#' @return A list of all call objects encountered during recursive traversal.
#' @details Called by `uses_call()` and `call_has_named_arg()`, and directly by
#'   current vector-question check chunks. Depends on its local recursive
#'   `visit()` helper.
walk_calls <- function(x) {
  calls <- list()

  #' Visit one node while recursively collecting calls
  #'
  #' @param node Parsed node from the expression tree.
  #' @return Invisibly, `NULL`; call nodes are appended to the enclosing
  #'   `calls` list as a side effect.
  #' @details Local recursive helper used only by `walk_calls()`.
  visit <- function(node) {
    if (is.expression(node)) {
      for (child in as.list(node)) visit(child)
      return(invisible(NULL))
    }

    if (!is.call(node)) return(invisible(NULL))

    calls[[length(calls) + 1L]] <<- node
    children <- as.list(node)[-1]
    # R represents an omitted call argument with a special sentinel. Inspect it
    # in place so valid forms such as x[rows, ] do not trigger evaluation errors.
    for (ii in seq_along(children)) {
      if (identical(children[[ii]], quote(expr = ))) next
      visit(children[[ii]])
    }
    invisible(NULL)
  }

  visit(x)
  calls
}

# Syntax predicates -----------------------------------------------------------

#' Test whether submitted code invokes a named function or operator
#'
#' Parses the submission, walks every nested call, and checks call heads against
#' the requested name. Current vector and data-frame question checks use this to
#' require specific syntax forms.
#'
#' @param code Character string containing submitted R code.
#' @param name Function or operator name to find.
#' @return A single logical value.
#' @details Called directly by check chunks in `question-bank/vector_drills.Rmd`
#'   and `question-bank/dataframe_drills.Rmd`, and by
#'   `uses_assignment_equals()`. Depends on `parse_student_code()`,
#'   `walk_calls()`, and `call_head()`.
uses_call <- function(code, name) {
  calls <- walk_calls(parse_student_code(code))
  any(vapply(calls, function(x) identical(call_head(x), name), logical(1)))
}

#' Test whether submitted code contains an exact token
#'
#' Performs a fixed-string search for syntax that may not survive parsing in a
#' distinguishable form, such as the native-pipe token.
#'
#' @param code Character string containing submitted R code.
#' @param token Exact token to search for.
#' @return A single logical value.
#' @details No current question-bank or runtime caller was found. This helper is
#'   presently available for future syntax checks and has no within-repo
#'   function dependencies.
uses_token <- function(code, token) {
  grepl(token, code, fixed = TRUE)
}

#' Test whether a call supplies a particular named argument
#'
#' Searches all nested calls to a named function and reports whether any such
#' call explicitly names the requested argument.
#'
#' @param code Character string containing submitted R code.
#' @param function_name Function name whose calls should be inspected.
#' @param argument_name Named argument to require.
#' @return A single logical value.
#' @details No current question-bank or runtime caller was found. Depends on
#'   `parse_student_code()`, `walk_calls()`, and `call_head()`.
call_has_named_arg <- function(code, function_name, argument_name) {
  calls <- walk_calls(parse_student_code(code))
  any(vapply(calls, function(x) {
    if (!identical(call_head(x), function_name)) return(FALSE)
    argument_name %in% names(as.list(x)[-1])
  }, logical(1)))
}

#' Test whether submitted code uses equals as assignment
#'
#' Uses parsed call structure so `=` assignment is distinguished from named
#' function arguments and default values.
#'
#' @param code Character string containing submitted R code.
#' @return A single logical value indicating whether an assignment call headed
#'   by `=` occurs.
#' @details No production caller currently uses this helper. It is exercised by
#'   `tests/testthat/test-syntax-checkers.R`. The global checker below performs
#'   its own self-contained traversal because learnr rebinds the checker's
#'   environment. Depends on `uses_call()`.
uses_assignment_equals <- function(code) {
  uses_call(code, "=")
}

# Global learnr checker -------------------------------------------------------

#' Run the Drillr exercise checker with assignment-style enforcement
#'
#' Detects `=` used as assignment in the submitted parse tree and, when found,
#' replaces the exercise's grading code with a targeted failure message before
#' delegating all grading to `gradethis::gradethis_exercise_checker()`. The
#' equals-assignment traversal is deliberately self-contained so the checker
#' still works after learnr rebinds its environment.
#'
#' @param label Exercise label passed by learnr.
#' @param solution_code Exercise solution code passed by learnr.
#' @param user_code Student submission passed by learnr.
#' @param check_code Exercise-specific grading code passed by learnr.
#' @param ... Additional arguments forwarded to
#'   `gradethis::gradethis_exercise_checker()`.
#' @return The feedback object returned by
#'   `gradethis::gradethis_exercise_checker()`.
#' @details Configured as the global exercise checker by
#'   `learnr::tutorial_options()` in `index.Rmd` and exercised by
#'   `test-syntax-checkers.R`. It does not depend on the other within-repo syntax
#'   helpers; it depends only on its local `contains_assignment_equals()`
#'   traversal before delegating to gradethis.
drillr_exercise_checker <- function(
  label = NULL,
  solution_code = NULL,
  user_code = NULL,
  check_code = NULL,
  ...
) {
  parsed <- tryCatch(parse(text = user_code), error = function(e) expression())

  #' Detect equals-assignment calls in a parsed tree
  #'
  #' @param node Parsed expression-tree node.
  #' @return `TRUE` when this node or any descendant is a call headed by `=`;
  #'   otherwise `FALSE`.
  #' @details Local recursive helper used only by `drillr_exercise_checker()`.
  contains_assignment_equals <- function(node) {
    if (is.expression(node)) {
      children <- as.list(node)
      if (!length(children)) return(FALSE)
      return(any(vapply(children, contains_assignment_equals, logical(1))))
    }

    if (!is.call(node)) return(FALSE)

    head <- node[[1]]
    if (is.symbol(head) && identical(as.character(head), "=")) return(TRUE)

    children <- as.list(node)[-1]
    # As in walk_calls(), skip omitted arguments without binding the sentinel to
    # a local variable, which would make R treat it as an evaluated missing arg.
    for (ii in seq_along(children)) {
      if (identical(children[[ii]], quote(expr = ))) next
      if (contains_assignment_equals(children[[ii]])) return(TRUE)
    }
    FALSE
  }

  if (contains_assignment_equals(parsed)) {
    check_code <- paste0(
      "grade_this({ fail(\"Use <- or -> for assignment. ",
      "Use = only for function arguments or defaults.\") })"
    )
  }

  gradethis::gradethis_exercise_checker(
    label = label,
    solution_code = solution_code,
    user_code = user_code,
    check_code = check_code,
    ...
  )
}
