
# - `gridsearch` ------------------------------------------------------------- #
# - function: grid search ---------------------------------------------------- #

### note: this function
###       (a) takes a panel dataframe (with `pid`, `t`, and `y`),
###       (b) iteratively prune to recover best DGPs,
###       (c) calculates error by measuring pattern distance from the DGPs.

# FUNCTION CALL -------------------------------------------------------------- #

#' Grid Search
#'
#' This function uses a three-step grid search algorithm to calculate the extent to which a dataframe can be approximated by a known DGP.
#' @param data A dataframe.
#' @param yname The outcome identifier.
#' @param tname The time identifier.
#' @param pname The unit identifier.
#' @param pattern If `pattern = contingency`, the calculations are based on the use of a contingency table of panel patterns; if `pattern = slopes`, the calculations are based on individual slope coefficients across time.
#' @param step1 The number of simulated datasets in Step 1.
#' @param step2 The number of simulated datasets in Step 2.
#' @param step3 The number of simulated datasets in Step 3.
#' @param reliability The reliability score of the outcome measurement.
#' @param seed Set seed.
#'
#' @return A data frame.
#' @export
#'

gridSearch <-

  function(

    # ----------------------------------------------------- #
    # FUNCTION ARGUMENTS AND WARNINGS                       #
    # ----------------------------------------------------- #

    # dataframe
    data,
    # outcome variable
    yname,
    # time variable
    tname,
    # person identifier
    pname,
    # pattern match
    pattern = c("contingency", "slopes"),
    # step 1 runs
    step1 = 30,
    # step 2 runs
    step2 = 120,
    # step 3 runs
    step3 = 480,
    # reliability
    reliability = 0.9,
    # seed
    seed = 11235

  ) {

    # --- dataframe

    df <- data |>
      dplyr::select(
        # get person identifier
        pid = {
          {
            pname
          }
        },
        # get time identifier
        t = {
          {
            tname
          }
        },
        # get outcome identifier
        y  = {
          {
            yname
          }
        }) |>
      dplyr::mutate(t = scales::rescale(t)) |>
      tidyr::drop_na()

    # --- messages!

    writeLines(
      "Warning: This function drops missing values. Tread carefully.")

    if(
      sort(unique(df$y))[1] == 0 &
      sort(unique(df$y))[2] == 1 &
      length(unique(df$y)) == 2) {
    } else{
      return(stop(
        "Error: The outcome needs to be binary and coded as 0 and 1."))
    }
    if(length(unique(df$t)) <= 1) {
      return(stop(
        "Error: There needs to be at least two time periods."))
    }
    if(step1 > step2 | step2 > step3 | step1 > step3) {
      return(stop(
        "Error: Each `step` should have higher runs than the previous ones."))
    }

    # ----------------------------------------------------- #
    # BUILDING BLOCKS                                       #
    # ----------------------------------------------------- #

    # --- part 1: initialize

    ## session
    future::plan(future::multisession)
    set.seed(seed)
    pattern = match.arg(pattern)

    # --- part 2: prepare the reference

    if (pattern == "contingency") {

      rf <- df |>
        tidyr::pivot_wider(names_from = "t", values_from = "y") |>
        janitor::clean_names() |>
        tidyr::unite("patterns", !pid, sep = "") |>
        dplyr::summarize(reference = dplyr::n(), .by = "patterns") |>
        dplyr::arrange(patterns) ## contingency of 0s and 1s across waves

    }

    if (pattern == "slopes") {

      rf <- gridsearch::varyingSlopes(df,
                                      pname = pid,
                                      tname = t,
                                      yname = y)

    }

    # --- part 3: fake-data grid

    fd <- tidyr::expand_grid(
      p_n =
        df |> dplyr::distinct(pid) |> nrow(),
      p_t =
        df |> dplyr::distinct(t) |> nrow(),
      p_rate =     seq(
        from = 0,
        to   = 1,
        length.out = 21
      ),
      p_strength = seq(
        from = 0.1,
        to   = 2,
        length.out = 20
      ),
      p_dir = c(0, 0.25, 0.50, 0.75, 1),
      p_res = df |> dplyr::pull(y) |> mean()
    ) |>
      ## round it up
      dplyr::mutate(p_rate = round(p_rate, 2),
                    p_strength = round(p_strength, 1))

    # --- part 4: function for parallelization

    parallel_grid <- function(dat) {

      if (pattern == "contingency") {

        dat <- dat |>
          dplyr::mutate(
            data =
              furrr::future_pmap(
                ## mapping list
                .l = list(p_n, p_t, p_strength, p_rate, p_dir, p_res),
                ## refer to list based on index
                .f = purrr::possibly(
                  ~ gridsearch::buildDGP(
                    # varying parameters
                    n = ..1,
                    t = ..2,
                    strength = ..3,
                    rate = ..4,
                    balance_dir = ..5,
                    balance_res = ..6,
                    reliable = reliability,
                    export = FALSE,
                    patterns = TRUE,
                    slopes = FALSE
                  )
                ),

                ## for reproducibility
                .options = furrr::furrr_options(seed = TRUE),
                .progress = TRUE
              )
          ) |>
          tidyr::unnest(data) |>
          dplyr::left_join(rf, by = "patterns") |>
          dplyr::mutate(reference = ifelse(is.na(reference) == TRUE, 0, reference)) |>
          dplyr::mutate(deviation = abs(sim_counts - reference)) |>
          dplyr::summarize(
            deviation_sum = sum(deviation),
            .by = c("p_rate", "p_strength", "p_dir", "sim")
          )

      }

      if (pattern == "slopes") {

        dat <- dat |>
          dplyr::mutate(
            data =
              furrr::future_pmap(
                ## mapping list
                .l = list(p_n, p_t, p_strength, p_rate, p_dir, p_res),
                ## refer to list based on index
                .f = purrr::possibly(
                  ~ gridsearch::buildDGP(
                    # varying parameters
                    n = ..1,
                    t = ..2,
                    strength = ..3,
                    rate = ..4,
                    balance_dir = ..5,
                    balance_res = ..6,
                    reliable = reliability,
                    export = FALSE,
                    patterns = FALSE,
                    slopes = TRUE
                  ) |>
                    dplyr::summarize(ks = stats::ks.test(estimate,
                                                         rf$estimate,
                                                         exact = TRUE)$statistic)
                ),
                ## for reproducibility
                .options = furrr::furrr_options(seed = TRUE),
                .progress = TRUE
              )
          )
      }

      return(dat)

    }

    # ----------------------------------------------------- #
    # GRID SEARCH ALGORITHM: CONTINGENCY                    #
    # ----------------------------------------------------- #

    if (pattern == "contingency") {

      writeLines(
        "\n We now start the calculations. There will be 3 steps.")

      # ----------------------------------------------------- #

      # --- search step 1

      writeLines(
        "\n Step 1 for grid search...")

      fd_1 <-
        tidyr::expand_grid(fd, sim = c(1:step1))
      fd_1 <- parallel_grid(fd_1)
      fd_1 <- fd_1 |>
        dplyr::summarize(
          error_1 = mean(deviation_sum),
          .by = c("p_rate", "p_strength", "p_dir")
        )

      # --- search step 1, mapping and cleaning
      fd <- fd |>
        dplyr::left_join(fd_1, by = c("p_rate", "p_strength", "p_dir"))

      # ----------------------------------------------------- #

      # --- search step 2

      writeLines(
        "\n Step 2 for grid search...")

      fd_2 <-
        tidyr::expand_grid(fd |>
                             dplyr::filter(error_1 <= stats::quantile(error_1, .5, na.rm = TRUE)),
                           sim = c(1:(step2 - step1)))
      fd_2 <- parallel_grid(fd_2)
      fd_2 <- fd_2 |>
        dplyr::summarize(
          error_2 = mean(deviation_sum),
          .by = c("p_rate", "p_strength", "p_dir")
        )

      # --- search step 2, mapping and cleaning
      fd <- fd |>
        dplyr::left_join(fd_2, by = c("p_rate", "p_strength", "p_dir")) |>
        ## update the error term for group 2
        dplyr::mutate(error_2 = dplyr::case_when(
          is.na(error_1) == TRUE ~ NA_real_,
          TRUE ~
            (step1 / (step1 + step2)) * error_1
          +
            (step2 / (step1 + step2)) * error_2
        ))

      # ----------------------------------------------------- #

      # --- search step 3

      writeLines(
        "\n Step 3 for grid search...")

      fd_3 <-
        tidyr::expand_grid(fd |>
                             dplyr::filter(error_2 <= stats::quantile(error_2, .2, na.rm = TRUE)),
                           sim = c(1:(step3 - step2)))
      fd_3 <- parallel_grid(fd_3)
      fd_3 <- fd_3 |>
        dplyr::summarize(
          error_3 = mean(deviation_sum),
          .by = c("p_rate", "p_strength", "p_dir")
        )

      # --- search step 3, mapping and cleaning
      fd <- fd |>
        dplyr::left_join(fd_3, by = c("p_rate", "p_strength", "p_dir")) |>
        ## update the error term for group 3
        dplyr::mutate(error_3 = dplyr::case_when(
          is.na(error_2) == TRUE ~ NA_real_,
          TRUE ~
            (step2 / (step2 + step3)) * error_2
          +
            (step3 / (step2 + step3)) * error_3
        ))

    }

    # ----------------------------------------------------- #
    # GRID SEARCH ALGORITHM: SLOPES                         #
    # ----------------------------------------------------- #

    if (pattern == "slopes") {

      writeLines(
        "\n We now start the calculations. There will be 3 steps.")

      # ----------------------------------------------------- #

      # --- search step 1

      writeLines(
        "\n Step 1 for grid search...")

      fd_1 <-
        tidyr::expand_grid(fd, sim = c(1:step1))
      fd_1 <- parallel_grid(fd_1)
      fd_1 <- fd_1 |>
        tidyr::unnest(cols = data) |>
        dplyr::summarize(ks_stat1 = mean(ks),
                         .by = c("p_rate", "p_strength", "p_dir"))

      # --- search step 1, mapping and cleaning
      fd <- fd |>
        dplyr::left_join(fd_1, by = c("p_rate", "p_strength", "p_dir"))

      # ----------------------------------------------------- #

      # --- search step 2

      writeLines(
        "\n Step 2 for grid search...")

      fd_2 <-
        tidyr::expand_grid(fd |>
                             dplyr::filter(ks_stat1 <= stats::quantile(ks_stat1, .5, na.rm = TRUE)),
                           sim = c(1:(step2 - step1)))
      fd_2 <- parallel_grid(fd_2)
      fd_2 <- fd_2 |>
        tidyr::unnest(cols = data) |>
        dplyr::summarize(ks_stat2 = mean(ks),
                         .by = c("p_rate", "p_strength", "p_dir"))

      # --- search step 2, mapping and cleaning
      fd <- fd |>
        dplyr::left_join(fd_2, by = c("p_rate", "p_strength", "p_dir")) |>
        ## update the error term for group 2
        dplyr::mutate(ks_stat2 = dplyr::case_when(
          is.na(ks_stat1) == TRUE ~ NA_real_,
          TRUE ~
            (step1 / (step1 + step2)) * ks_stat1
          +
            (step2 / (step1 + step2)) * ks_stat2
        ))

      # ----------------------------------------------------- #

      # --- search step 3

      writeLines(
        "\n Step 3 for grid search...")

      fd_3 <-
        tidyr::expand_grid(fd |>
                             dplyr::filter(ks_stat2 <= stats::quantile(ks_stat2, .2, na.rm = TRUE)),
                           sim = c(1:(step3 - step2)))
      fd_3 <- parallel_grid(fd_3)
      fd_3 <- fd_3 |>
        tidyr::unnest(cols = data) |>
        dplyr::summarize(ks_stat3 = mean(ks),
                         .by = c("p_rate", "p_strength", "p_dir"))

      # --- search step 3, mapping and cleaning
      fd <- fd |>
        dplyr::left_join(fd_3, by = c("p_rate", "p_strength", "p_dir")) |>
        ## update the error term for group 3
        dplyr::mutate(ks_stat3 = dplyr::case_when(
          is.na(ks_stat2) == TRUE ~ NA_real_,
          TRUE ~
            (step2 / (step2 + step3)) * ks_stat2
          +
            (step3 / (step2 + step3)) * ks_stat3
        ))

    }

    # ----------------------------------------------------- #
    # EXPORT                                                #
    # ----------------------------------------------------- #

    if (pattern == "contingency") {

      fd <- fd |>
        ## cleanup
        dplyr::mutate(p_dir = factor(
          p_dir,
          levels = c(0, 0.25, 0.5, 0.75, 1),
          labels = c(
            "100% Down",
            "75% Down-25% Up",
            "50% Down-50% Up",
            "25% Down-75% Up",
            "100% Up"
          )
        )) |>
        dplyr::mutate(error = error_3) |>
        dplyr::mutate(error = ifelse(is.na(error) == TRUE, error_2, error)) |>
        dplyr::mutate(error = ifelse(is.na(error) == TRUE, error_1, error)) |>
        dplyr::select(
          rate = p_rate,
          strength = p_strength,
          direction = p_dir,
          error
        ) |>
        dplyr::mutate(pattern = "contingency")

      return(fd)

    }

    if (pattern == "slopes") {

      fd <- fd |>
        ## cleanup
        dplyr::mutate(p_dir = factor(
          p_dir,
          levels = c(0, 0.25, 0.5, 0.75, 1),
          labels = c(
            "100% Down",
            "75% Down-25% Up",
            "50% Down-50% Up",
            "25% Down-75% Up",
            "100% Up"
          )
        )) |>
        dplyr::mutate(ks_stat = ks_stat3) |>
        dplyr::mutate(ks_stat = ifelse(is.na(ks_stat) == TRUE, ks_stat2, ks_stat)) |>
        dplyr::mutate(ks_stat = ifelse(is.na(ks_stat) == TRUE, ks_stat1, ks_stat)) |>
        dplyr::select(
          rate = p_rate,
          strength = p_strength,
          direction = p_dir,
          error = ks_stat
        ) |>
        dplyr::mutate(pattern = "slopes")

      return(fd)

    }

  }

# ---------------------------------------------------------------------------- #
