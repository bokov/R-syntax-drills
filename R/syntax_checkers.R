# Helpers for checking whether submitted R code uses a requested syntax form.
# Most checks inspect parsed R code. uses_token() is available for syntax that
# R normalizes while parsing (notably the native pipe).

parse_student_code <- function(code) {
  tryCatch(parse(text = code), error = function(e) expression())
}

call_head <- function(x) {
  if (!is.call(x)) return(NA_character_)
  head <- x[[1]]
  if (is.symbol(head)) return(as.character(head))
  if (is.call(head) && identical(as.character(head[[1]]), "::")) {
    return(as.character(head[[3]]))
  }
  NA_character_
}

walk_calls <- function(x) {
  calls <- list()

  visit <- function(node) {
    if (is.expression(node)) {
      for (child in as.list(node)) visit(child)
      return(invisible(NULL))
    }

    if (!is.call(node)) return(invisible(NULL))

    calls[[length(calls) + 1L]] <<- node
    children <- as.list(node)[-1]
    for (child in children) visit(child)
    invisible(NULL)
  }

  visit(x)
  calls
}

uses_call <- function(code, name) {
  calls <- walk_calls(parse_student_code(code))
  any(vapply(calls, function(x) identical(call_head(x), name), logical(1)))
}

uses_token <- function(code, token) {
  grepl(token, code, fixed = TRUE)
}

call_has_named_arg <- function(code, function_name, argument_name) {
  calls <- walk_calls(parse_student_code(code))
  any(vapply(calls, function(x) {
    if (!identical(call_head(x), function_name)) return(FALSE)
    argument_name %in% names(as.list(x)[-1])
  }, logical(1)))
}

uses_assignment_equals <- function(code) {
  uses_call(code, "=")
}

drillr_exercise_checker <- function(
  label = NULL,
  solution_code = NULL,
  user_code = NULL,
  check_code = NULL,
  envir_prep = NULL,
  ...
) {
  parsed <- tryCatch(parse(text = user_code), error = function(e) expression())

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
    if (!length(children)) return(FALSE)
    any(vapply(children, contains_assignment_equals, logical(1)))
  }

  if (is.environment(envir_prep)) {
    runtime_parse_student_code <- function(code) {
      tryCatch(parse(text = code), error = function(e) expression())
    }

    runtime_call_head <- function(x) {
      if (!is.call(x)) return(NA_character_)
      head <- x[[1]]
      if (is.symbol(head)) return(as.character(head))
      if (is.call(head) && identical(as.character(head[[1]]), "::")) {
        return(as.character(head[[3]]))
      }
      NA_character_
    }

    runtime_walk_calls <- function(x) {
      calls <- list()

      visit <- function(node) {
        if (is.expression(node)) {
          for (child in as.list(node)) visit(child)
          return(invisible(NULL))
        }

        if (!is.call(node)) return(invisible(NULL))

        calls[[length(calls) + 1L]] <<- node
        children <- as.list(node)[-1]
        for (child in children) visit(child)
        invisible(NULL)
      }

      visit(x)
      calls
    }

    runtime_uses_call <- function(code, name) {
      calls <- runtime_walk_calls(runtime_parse_student_code(code))
      any(vapply(
        calls,
        function(x) identical(runtime_call_head(x), name),
        logical(1)
      ))
    }

    runtime_uses_token <- function(code, token) {
      grepl(token, code, fixed = TRUE)
    }

    runtime_call_has_named_arg <- function(code, function_name, argument_name) {
      calls <- runtime_walk_calls(runtime_parse_student_code(code))
      any(vapply(calls, function(x) {
        if (!identical(runtime_call_head(x), function_name)) return(FALSE)
        argument_name %in% names(as.list(x)[-1])
      }, logical(1)))
    }

    runtime_uses_assignment_equals <- function(code) {
      runtime_uses_call(code, "=")
    }

    list2env(
      list(
        parse_student_code = runtime_parse_student_code,
        call_head = runtime_call_head,
        walk_calls = runtime_walk_calls,
        uses_call = runtime_uses_call,
        uses_token = runtime_uses_token,
        call_has_named_arg = runtime_call_has_named_arg,
        uses_assignment_equals = runtime_uses_assignment_equals
      ),
      envir = envir_prep
    )
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
    envir_prep = envir_prep,
    ...
  )
}
