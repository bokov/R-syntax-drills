# Helpers for recursive expression-decomposition drills.
#
# Source this file from the tutorial setup chunk:
#   source("R/expression_decomposition.R")
#
# Each drill calls expression_decomposition_quiz("some R expression").
# The helper parses the expression but NEVER evaluates it.

# Expression rendering and classification ------------------------------------

#' Convert a parsed R object to compact source text
#'
#' Deparses an expression, call, symbol, or literal onto one display string for
#' quiz prompts, answer labels, and the instructor tree printer.
#'
#' @param x Parsed R object to render.
#' @return A length-one character representation of `x`.
#' @details Called by `.decomp_call_name()`, `.decomp_expr_answer()`,
#'   `.decomp_questions()`, and `print_expression_tree()`. It has no within-repo
#'   function dependencies.
.decomp_text <- function(x) {
  paste(deparse(x, width.cutoff = 500L), collapse = " ")
}

#' Test whether a parsed argument is deliberately missing
#'
#' Wraps `rlang::is_missing()` so recursive decomposition can distinguish blank
#' arguments such as the column position in `x[rows, ]` from ordinary atoms.
#'
#' @param x Parsed argument object.
#' @return A single logical value.
#' @details Called by `.decomp_questions()` and the local tree walker inside
#'   `print_expression_tree()`. It has no within-repo function dependencies.
.decomp_is_missing <- function(x) {
  rlang::is_missing(x)
}

#' Return the displayed function/operator name of a call
#'
#' Deparses the head of a parsed call so functions and operators can be asked
#' about uniformly in recursive expression-decomposition drills.
#'
#' @param x Parsed R call.
#' @return A length-one character function/operator name.
#' @details Called by `.decomp_questions()` and the local tree walker in
#'   `print_expression_tree()`. Depends on `.decomp_text()`.
.decomp_call_name <- function(x) {
  if (!is.call(x)) stop("x is not a call.")
  .decomp_text(x[[1]])
}

#' Classify a terminal parsed atom for student questions
#'
#' Maps symbols, literal storage types, and `NULL` to the vocabulary taught by
#' the decomposition drill, falling back to a `typeof()`-based atom label.
#'
#' @param x Parsed non-call object.
#' @return A length-one character atom-type label.
#' @details Called by `.decomp_questions()` and the local tree walker in
#'   `print_expression_tree()`. It has no within-repo function dependencies.
.decomp_atom_type <- function(x) {
  if (is.symbol(x)) return("symbol")
  if (is.character(x)) return("character literal")
  if (is.logical(x)) return("logical literal")
  if (is.integer(x)) return("integer literal")
  if (is.double(x)) return("numeric literal")
  if (is.complex(x)) return("complex literal")
  if (is.null(x)) return("NULL")
  paste0(typeof(x), " atom")
}

#' Normalize a typed function or argument name
#'
#' Trims whitespace and removes matching backticks so students can enter either
#' syntactic or backticked spellings of operator/function names.
#'
#' @param x Character answer supplied by the student.
#' @return The normalized character answer.
#' @details Called only by the answer callback created by
#'   `.decomp_text_answer()`. It has no within-repo function dependencies.
.decomp_normalize_name <- function(x) {
  x <- trimws(x)
  if (nchar(x) >= 2L && substr(x, 1L, 1L) == "`" &&
      substr(x, nchar(x), nchar(x)) == "`") {
    x <- substr(x, 2L, nchar(x) - 1L)
  }
  x
}

# Learnr answer builders ------------------------------------------------------

#' Build a text-answer checker for an exact normalized name
#'
#' Creates a learnr answer function that accepts the expected function/operator
#' or named-argument text and otherwise returns either a supplied hint or an
#' exact-answer message.
#'
#' @param expected Normalized answer text that should be accepted.
#' @param hint Optional custom incorrect-answer message.
#' @return A learnr answer object returned by `learnr::answer_fn()`.
#' @details Called by `.decomp_questions()` for call-head and named-argument
#'   questions. The anonymous answer callback depends on
#'   `.decomp_normalize_name()` and closes over `expected` and `hint`.
.decomp_text_answer <- function(expected, hint = NULL) {
  force(expected)
  force(hint)

  learnr::answer_fn(
    # Validate one student-entered function/operator or argument name.
    function(value) {
      if (identical(.decomp_normalize_name(value), expected)) {
        learnr::correct()
      } else {
        msg <- if (is.null(hint)) {
          paste0("Expected `", expected, "`.")
        } else {
          hint
        }
        learnr::incorrect(msg)
      }
    },
    label = expected
  )
}

#' Build a text-answer checker for an exact R expression
#'
#' Parses a student's answer without evaluating it and accepts it only when the
#' resulting single expression is structurally identical to the expected parsed
#' argument.
#'
#' @param expected Parsed R expression expected as the answer.
#' @return A learnr answer object returned by `learnr::answer_fn()`.
#' @details Called by `.decomp_questions()` for argument-expression questions.
#'   Its anonymous callback depends on `.decomp_text()` and closes over
#'   `expected`.
.decomp_expr_answer <- function(expected) {
  force(expected)

  learnr::answer_fn(
    # Parse and structurally compare one student-entered R expression.
    function(value) {
      parsed <- tryCatch(
        parse(text = value, keep.source = FALSE),
        error = function(e) NULL
      )

      if (is.null(parsed) || length(parsed) != 1L) {
        return(learnr::incorrect("Enter one valid R expression."))
      }

      if (identical(parsed[[1]], expected)) {
        learnr::correct()
      } else {
        learnr::incorrect(
          paste0("That is not the same expression as `", .decomp_text(expected), "`.")
        )
      }
    },
    label = .decomp_text(expected)
  )
}

#' Build a call/atom/missing classification question
#'
#' Creates the fixed three-choice radio question used at every argument node in
#' the expression tree.
#'
#' @param prompt Student-facing question text.
#' @param kind Correct classification: `"call"`, `"atom"`, or `"missing"`.
#' @return A learnr radio-question object.
#' @details Called only by `.decomp_questions()`. It has no within-repo function
#'   dependencies.
.decomp_kind_question <- function(prompt, kind) {
  learnr::question_radio(
    prompt,
    learnr::answer("a function/operator call", correct = identical(kind, "call")),
    learnr::answer("an atom", correct = identical(kind, "atom")),
    learnr::answer("a missing argument", correct = identical(kind, "missing")),
    allow_retry = TRUE,
    random_answer_order = FALSE
  )
}

#' Build a terminal-atom classification question
#'
#' Creates the fixed vocabulary radio question that asks students to classify a
#' leaf of the expression tree.
#'
#' @param prompt Student-facing question text.
#' @param atom_type Correct atom-type label returned by `.decomp_atom_type()`.
#' @return A learnr radio-question object.
#' @details Called only by `.decomp_questions()`. The anonymous `lapply()`
#'   callback creates one `learnr::answer()` for each allowed atom type.
.decomp_atom_question <- function(prompt, atom_type) {
  choices <- c(
    "symbol",
    "numeric literal",
    "integer literal",
    "character literal",
    "logical literal",
    "complex literal",
    "NULL"
  )

  answers <- lapply(
    choices,
    # Convert each atom-type vocabulary entry to a learnr answer choice.
    function(xx) learnr::answer(xx, correct = identical(xx, atom_type))
  )

  do.call(
    learnr::question_radio,
    c(
      list(text = prompt),
      answers,
      list(
        allow_retry = TRUE,
        random_answer_order = FALSE
      )
    )
  )
}

# Recursive quiz construction ------------------------------------------------

#' Build all decomposition questions for one call node
#'
#' Recursively walks a parsed call, asking for its call head and argument count,
#' then for each argument's optional name, exact expression, kind, and either
#' nested decomposition or terminal atom type.
#'
#' @param node Parsed R call at the current recursion level.
#' @param path Human-readable description of the current node's location in the
#'   original expression.
#' @return A list of learnr question objects in traversal order.
#' @details Called by `expression_decomposition_quiz()` and recursively by
#'   itself. Depends on `.decomp_text()`, `.decomp_call_name()`,
#'   `.decomp_text_answer()`, `.decomp_is_missing()`, `.decomp_kind_question()`,
#'   `.decomp_expr_answer()`, `.decomp_atom_question()`, and
#'   `.decomp_atom_type()`.
.decomp_questions <- function(node, path = "the whole expression") {
  if (!is.call(node)) {
    stop(".decomp_questions() must begin with a call.")
  }

  questions <- list()

  call_text <- .decomp_text(node)
  fn_name <- .decomp_call_name(node)
  args <- as.list(node)[-1L]
  arg_names <- names(args)
  if (is.null(arg_names)) arg_names <- rep("", length(args))

  questions[[length(questions) + 1L]] <- learnr::question_text(
    paste0(
      "For ", path, " (`", call_text,
      "`), what function or operator is being called?"
    ),
    .decomp_text_answer(fn_name),
    allow_retry = TRUE,
    placeholder = "Function/operator"
  )

  questions[[length(questions) + 1L]] <- learnr::question_numeric(
    paste0(
      "How many arguments does that `", fn_name,
      "` call have? Count a deliberately blank argument as an argument."
    ),
    learnr::answer(length(args), correct = TRUE),
    allow_retry = TRUE,
    min = 0,
    step = 1
  )

  for (i in seq_along(args)) {
    arg <- args[[i]]
    arg_name <- arg_names[[i]]
    arg_path <- paste0("argument ", i, " of `", call_text, "`")

    if (nzchar(arg_name)) {
      questions[[length(questions) + 1L]] <- learnr::question_text(
        paste0(
          "Argument ", i, " of `", call_text,
          "` is a named argument. What is its argument name?"
        ),
        .decomp_text_answer(arg_name),
        allow_retry = TRUE,
        placeholder = "Argument name"
      )
    }

    if (.decomp_is_missing(arg)) {
      questions[[length(questions) + 1L]] <- .decomp_kind_question(
        paste0(
          "Classify ", arg_path,
          ". Is it a call, an atom, or a missing argument?"
        ),
        "missing"
      )
      next
    }

    questions[[length(questions) + 1L]] <- learnr::question_text(
      paste0(
        "What is ", arg_path,
        ", exactly as an R expression?"
      ),
      .decomp_expr_answer(arg),
      allow_retry = TRUE,
      placeholder = "R expression"
    )

    kind <- if (is.call(arg)) "call" else "atom"

    questions[[length(questions) + 1L]] <- .decomp_kind_question(
      paste0(
        "Classify ", arg_path,
        " (`", .decomp_text(arg),
        "`). Is it a call, an atom, or a missing argument?"
      ),
      kind
    )

    if (is.call(arg)) {
      questions <- c(
        questions,
        .decomp_questions(
          arg,
          path = paste0(arg_path, " = `", .decomp_text(arg), "`")
        )
      )
    } else {
      questions[[length(questions) + 1L]] <- .decomp_atom_question(
        paste0(
          "At the bottom of this branch, what kind of atom is `",
          .decomp_text(arg), "`?"
        ),
        .decomp_atom_type(arg)
      )
    }
  }

  questions
}

#' Build a learnr quiz that recursively decomposes one R expression
#'
#' Parses exactly one top-level call without evaluating it, recursively creates
#' decomposition questions for the complete call tree, and combines those
#' questions into one learnr quiz.
#'
#' @param expression_text Character source containing exactly one R expression.
#' @param caption Quiz caption displayed by learnr.
#' @return A learnr quiz object.
#' @details Called by every drill in
#'   `question-bank/expression_decomposition_drills.Rmd`. Depends on
#'   `.decomp_questions()`.
expression_decomposition_quiz <- function(expression_text, caption = "Expression decomposition") {
  parsed <- parse(text = expression_text, keep.source = FALSE)

  if (length(parsed) != 1L) {
    stop("expression_text must contain exactly one R expression.")
  }

  expr <- parsed[[1L]]

  if (!is.call(expr)) {
    stop("The top-level expression must be a function/operator call.")
  }

  questions <- .decomp_questions(expr)

  do.call(
    learnr::quiz,
    c(
      questions,
      list(caption = caption)
    )
  )
}

# Instructor inspection -------------------------------------------------------

# Instructor helper: print the same expression as an indented recursive tree.

#' Print a parsed expression as an indented recursive tree
#'
#' Parses one expression without evaluating it and prints each node as a CALL,
#' ATOM, or missing argument, including argument names and atom classifications,
#' for instructor inspection/debugging of decomposition drills.
#'
#' @param expression_text Character source containing exactly one R expression.
#' @return Invisibly, the parsed top-level expression after printing its tree.
#' @details No within-repository caller was found; this is an instructor-facing
#'   helper intended to be called directly. Depends on its local recursive
#'   `walk()` helper, which in turn uses `.decomp_is_missing()`,
#'   `.decomp_atom_type()`, `.decomp_text()`, and `.decomp_call_name()`.
print_expression_tree <- function(expression_text) {
  parsed <- parse(text = expression_text, keep.source = FALSE)
  if (length(parsed) != 1L) stop("Provide exactly one expression.")

  #' Print one node of an expression tree and recurse into call arguments
  #'
  #' @param node Parsed expression-tree node.
  #' @param indent Integer indentation depth.
  #' @param label Label printed before the node description.
  #' @return Invisibly, `NULL` after printing the node and any descendants.
  #' @details Local recursive helper used only by `print_expression_tree()`.
  walk <- function(node, indent = 0L, label = "ROOT") {
    pad <- paste(rep("  ", indent), collapse = "")

    if (.decomp_is_missing(node)) {
      cat(pad, label, ": <MISSING>\n", sep = "")
      return(invisible(NULL))
    }

    if (!is.call(node)) {
      cat(
        pad, label, ": ATOM [", .decomp_atom_type(node), "] ",
        .decomp_text(node), "\n",
        sep = ""
      )
      return(invisible(NULL))
    }

    cat(
      pad, label, ": CALL ", .decomp_call_name(node),
      "  =>  ", .decomp_text(node), "\n",
      sep = ""
    )

    args <- as.list(node)[-1L]
    arg_names <- names(args)
    if (is.null(arg_names)) arg_names <- rep("", length(args))

    for (i in seq_along(args)) {
      nm <- if (nzchar(arg_names[[i]])) paste0(" [name=", arg_names[[i]], "]") else ""
      walk(args[[i]], indent + 1L, paste0("ARG", i, nm))
    }

    invisible(NULL)
  }

  walk(parsed[[1L]])
  invisible(parsed[[1L]])
}
