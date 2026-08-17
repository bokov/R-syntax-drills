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
