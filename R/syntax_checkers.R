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

call_count <- function(code, name) {
  calls <- walk_calls(parse_student_code(code))
  sum(vapply(calls, function(x) identical(call_head(x), name), logical(1)))
}

uses_nested_subscript <- function(code) {
  calls <- walk_calls(parse_student_code(code))

  any(vapply(calls, function(x) {
    identical(call_head(x), "[") &&
      length(x) >= 2 &&
      is.call(x[[2]]) &&
      identical(call_head(x[[2]]), "[")
  }, logical(1)))
}

subscript_uses_call <- function(code, name) {
  calls <- walk_calls(parse_student_code(code))

  any(vapply(calls, function(x) {
    if (!identical(call_head(x), "[") || length(x) < 3) return(FALSE)

    subscripts <- as.list(x)[-(1:2)]
    any(vapply(subscripts, function(node) {
      if (!is.call(node)) return(FALSE)
      nested <- walk_calls(node)
      any(vapply(
        nested,
        function(call_obj) identical(call_head(call_obj), name),
        logical(1)
      ))
    }, logical(1)))
  }, logical(1)))
}

assigns_to <- function(code, name) {
  calls <- walk_calls(parse_student_code(code))

  any(vapply(calls, function(x) {
    head <- call_head(x)

    if (head %in% c("<-", "=", "<<-") && length(x) >= 3) {
      target <- x[[2]]
      return(is.symbol(target) && identical(as.character(target), name))
    }

    if (head %in% c("->", "->>") && length(x) >= 3) {
      target <- x[[3]]
      return(is.symbol(target) && identical(as.character(target), name))
    }

    if (identical(head, "assign") && length(x) >= 3) {
      target <- x[[2]]
      return(is.character(target) && length(target) == 1 && identical(target, name))
    }

    FALSE
  }, logical(1)))
}

check_vector_assignment <- function(
  code,
  result_env,
  variable_name,
  expected_value,
  required_calls = character()
) {
  if (!assigns_to(code, variable_name)) {
    return(gradethis::fail(
      paste0("Assign the vector to `", variable_name, "` as requested.")
    ))
  }

  for (required_call in required_calls) {
    if (!uses_call(code, required_call)) {
      label <- if (identical(required_call, ":")) {
        "the `:` operator"
      } else {
        paste0("`", required_call, "()`")
      }
      return(gradethis::fail(paste0("Use ", label, " as requested.")))
    }
  }

  if (!exists(variable_name, envir = result_env, inherits = FALSE)) {
    return(gradethis::fail(
      paste0("Create the variable `", variable_name, "`.")
    ))
  }

  assigned_value <- get(variable_name, envir = result_env, inherits = FALSE)
  if (!isTRUE(all.equal(assigned_value, expected_value, check.attributes = TRUE))) {
    return(gradethis::fail(
      "The assigned vector does not match the requested values and names."
    ))
  }

  gradethis::pass("Correct.")
}

check_vector_subscript <- function(
  code,
  returned_value,
  expected_value,
  required_calls = character(),
  min_brackets = 1L
) {
  if (!uses_call(code, "[")) {
    return(gradethis::fail("Use single-bracket vector subscripting (`[ ]`)."))
  }

  if (call_count(code, "[") < min_brackets) {
    return(gradethis::fail(
      "Subset a subvector again using a second pair of `[ ]` brackets."
    ))
  }

  if (min_brackets >= 2L && !uses_nested_subscript(code)) {
    return(gradethis::fail(
      "Subset the result of one `[ ]` operation with another `[ ]` operation."
    ))
  }

  for (required_call in required_calls) {
    if (!subscript_uses_call(code, required_call)) {
      label <- if (identical(required_call, "%in%")) {
        "`%in%`"
      } else {
        paste0("`", required_call, "()`")
      }
      return(gradethis::fail(
        paste0("Use ", label, " inside the subscript as requested.")
      ))
    }
  }

  if (!isTRUE(all.equal(
    unname(returned_value),
    unname(expected_value),
    check.attributes = FALSE
  ))) {
    return(gradethis::fail("The returned value or subvector is not correct."))
  }

  gradethis::pass("Correct.")
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
