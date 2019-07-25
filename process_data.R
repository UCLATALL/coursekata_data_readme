
# Required packages and functions -----------------------------------------

# load required packages, installing if needed
if (!require("pacman", quietly = TRUE)) install.packages("pacman")
pacman::p_load(
  jsonlite, dplyr, tidyverse, readr, purrr, stringr, lubridate,
  future, furrr
)

# setup the future/furrr package
future::plan("future::multiprocess")

# define some helper functions that will be useful later
json_to_list <- function(x) {
  if (is.null(x) | is.na(x)) list() else parse_json(x)
}

# read in dates as UTC timezone and then convert to system timezone
convert_date_string <- function(x) {
  ymd_hms(x, tz = "UTC") %>% with_tz(Sys.timezone())
}


# Read in responses -------------------------------------------------------

# for responses, the number of columns is variable so we don't know the types
# readr will try to guess the types, but col_guess() is unreliable
# instead just read everything in as a character column and then convert after
responses <- "responses.csv" %>%
  read_csv(col_types = cols(.default = col_character())) %>%
  mutate_at(vars(attempt, lrn_question_position), parse_integer) %>%
  mutate_at(vars(points_possible, points_earned), parse_number) %>%
  # read in dates as UTC timezone and then convert to system timezone
  mutate_at(vars(matches("^(?:lrn_)?dt_")), convert_date_string) %>%
  # convert response JSON to a nested list-column then move it to the end
  mutate(lrn_response_json = map(lrn_response_json, json_to_list)) %>%
  select(-lrn_response_json, lrn_response_json) %>%
  drop_na(student_id, prompt, response)


# Process response values -------------------------------------------------
# Convert multiple choice response value arrays to actual values
# NOTE: this code chunk can take a couple minutes to run

lookup_table <- responses %>%
  filter(lrn_type == "mcq") %>%
  select(reference = lrn_question_reference, starts_with("lrn_option_")) %>%
  distinct()

lookup_response <- function(response, reference, lookup_table) {
  if (response == "[]" | is.na(response)) {
    return(NA)
  }
  if (!str_detect(response, '\\[(?:"\\d+",? ?)\\]')) {
    return(response)
  }
  if (!reference %in% lookup_table$reference) {
    return(response)
  }

  option_nums <- response %>%
    str_split(",", simplify = TRUE) %>%
    parse_number() %>%
    as.integer()

  lookup_table[lookup_table$reference == reference, option_nums + 2] %>%
    as.character() %>%
    paste0(collapse = "; ")
}

responses <- responses %>%
  mutate(response = future_map2_chr(
    response, lrn_question_reference,
    lookup_response,
    lookup_table = lookup_table,
    .progress = TRUE
  ))


# Split responses into useful tables --------------------------------------

students <- responses %>%
  filter(str_detect(item_id, "Student_Survey_Pre|Post-Survey")) %>%
  drop_na(student_id, prompt, response) %>%
  mutate(prompt = ifelse(
    str_detect(item_id, "Student_Survey"),
    paste("pre:", prompt),
    paste("post:", prompt)
  )) %>%
  # only keep most recent response
  arrange(desc(dt_submitted)) %>%
  distinct(student_id, prompt, .keep_all = TRUE) %>%
  # spread each prompt to its own column
  select(
    -starts_with("lrn_"), -attempt, -release, -dt_submitted,
    -points_possible, -points_earned,
    -chapter, -page, -item_id, -item_type, -user_agent
  ) %>%
  spread(prompt, response) %>%
  # rearrange the columns
  select(
    class_id, course_name, branch, student_id,
    starts_with("pre: "), starts_with("post: ")
  )

textbook_items <- responses %>%
  filter(!str_detect(item_id, "Student_Survey|Post-Survey|Practice Quiz")) %>%
  drop_na(prompt, response)

practice_quizzes <- responses %>%
  filter(str_detect(page, "Practice Quiz"))


# Read in page views ------------------------------------------------------

page_views <- "page-views.csv" %>%
  read_csv(col_types = cols(.default = col_character())) %>%
  # read in dates as UTC timezone and then convert to system timezone
  mutate(dt_accessed = convert_date_string(dt_accessed))


# Read in items -----------------------------------------------------------

items <- "items.csv" %>%
  read_csv(col_types = cols(.default = col_character())) %>%
  mutate(
    lrn_question_position = parse_integer(lrn_question_position),
    lrn_question_data = map(lrn_question_data, json_to_list)
  )


# Read in tags ------------------------------------------------------------

tags <- "tags.csv" %>%
  read_csv(col_types = cols(.default = col_character()))


# Save Data to Disk -------------------------------------------------------

write_rds(items, "items.Rds", compress = "gz")
write_rds(page_views, "page_views.Rds", compress = "gz")
write_rds(tags, "tags.Rds", compress = "gz")
write_rds(responses, "responses.Rds", compress = "gz")
write_rds(students, "students.Rds", compress = "gz")
write_rds(textbook_items, "textbook_items.Rds", compress = "gz")
write_rds(practice_quizzes, "practice_quizzes.Rds", compress = "gz")


# Clean up helper functions -----------------------------------------------

# clears out the environment so that only the data holding variables are left
rm(lookup_table, lookup_response, json_to_list, convert_date_string)
