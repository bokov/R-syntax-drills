# Helpers for recursive expression-decomposition drills.
#
# Source this file from the tutorial setup chunk:
#   source("R/expression_decomposition.R")
#
# Each drill calls expression_decomposition_quiz("some R expression").
# The helper parses the expression but NEVER evaluates it.

.decomp_text <- function(x) {
  paste(deparse(x, width.cutoff = 500L), collapse = " ")
}

.decomp_is_missing <- function(x) {
  rlang::is_missing(x)
}

.decomp_call_name <- function(x) {
  if (!is.call(x)) stop("x is not a call.")
  .decomp_text(x[[1]])
}

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

.decomp_normalize_name <- function(x) {
  x <- trimws(x)
  if (nchar(x) >= 2L && substr(x, 1L, 1L) == "`" &&
      substr(x, nchar(x), nchar(x)) == "`") {
    x <- substr(x, 2L, nchar(x) - 1L)
  }
  x
}

.decomp_text_answer <- function(expected, hint = NULL) {
  force(expected)
  force(hint)

  learnr::answer_fn(
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

.decomp_expr_answer <- function(expected) {
  force(expected)

  learnr::answer_fn(
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

# Instructor helper: print the same expression as an indented recursive tree.
print_expression_tree <- function(expression_text) {
  parsed <- parse(text = expression_text, keep.source = FALSE)
  if (length(parsed) != 1L) stop("Provide exactly one expression.")

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
