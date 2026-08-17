# Expression decomposition drill bank

This bank contains **50 recursive drills** for learning to parse complex R expressions all the way down to atoms.

## Files

- `R/expression_decomposition.R` — reusable quiz generator and instructor tree-printer.
- `expression_decomposition_drills.Rmd` — 50 ready-to-paste drill sections.
- `scripts/print_answer_trees.R` — prints a complete recursive answer tree for every expression.

## Installation into the existing learnr project

Copy `R/expression_decomposition.R` into the project's `R/` directory and add this to the tutorial setup chunk:

```r
source("R/expression_decomposition.R")
```

Then paste any desired drill sections from `expression_decomposition_drills.Rmd`.

## Pedagogical behavior

A student does **not** enter a special tree notation. Each expression expands into a sequence of automatically graded `learnr` questions. R-fragment answers are parsed and compared as R expressions, so harmless whitespace and quote-style differences do not cause a wrong answer.

The drills intentionally teach that operators are calls too. For example, `x[1:3]` decomposes through `[` and then `:`; `mtcars$mpg` decomposes through `$`; and `x <- f(y)` decomposes through `<-`.

The helper uses `rlang::is_missing()` to recognize deliberately blank arguments such as the column argument in `iris[iris$Species == "setosa", ]`. `rlang` is already a dependency of `learnr`.
