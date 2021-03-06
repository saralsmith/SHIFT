# Module UI

#' @title   mod_load_data_ui and mod_load_data_server
#' @description  A shiny Module.
#'
#' @param id shiny id
#' @param input internal
#' @param output internal
#' @param session internal
#'
#' @rdname mod_load_data
#'
#' @keywords internal
#' @export
#' @importFrom shiny NS tagList fileInput actionButton downloadButton downloadHandler
#' @importFrom DT renderDT DTOutput
#' @importFrom shinyWidgets switchInput
mod_load_data_ui <- function(id) {
  ns <- NS(id)
  tagList(
    fluidRow(
      box(
        width = 12,
        status = "primary",
        solidHeader = TRUE,
        collapsible = TRUE,
        collapsed = FALSE,
        title = "Load your data here.",

        fileInput(
          ns("file"),
          "Choose a file or files",
          accept = c(
            ".csv",
            ".xlxs",
            ".R",
            ".rds"
          ),
          multiple = TRUE
        ),

        switchInput(
          ns("overwrite"),
          onLabel = "Overwrite",
          offLabel = "Append",
          value = TRUE,
          inline = TRUE,
          size = "small"
        ),

        DTOutput(ns("user_DT")),

        actionButton(
          ns("undo"),
          label = "Undo Last",
          icon = icon("undo")
        ),

        actionButton(
          ns("keep_col"),
          label = "Keep Selected"
        ),

        actionButton(
          ns("drop_col"),
          label = "Drop Selected"
        ),

        downloadButton(
          ns("download_data"),
          label = "Download"
        ),

        switchInput(
          ns("diff"),
          onLabel = "Differenced",
          offLabel = "Not Differenced",
          value = FALSE,
          inline = TRUE,
          size = "normal"
        ),


        tags$br(),
        uiOutput(ns("RangeHistorical"))
        # uiOutput(ns("RangeProjections"))
      )
    )
  )
}

# Module Server

#' @rdname mod_load_data
#' @export
#' @keywords internal
#' @importFrom lubridate yq year quarter
#' @importFrom zoo na.trim as.yearqtr
#' @importFrom dplyr select relocate
#' @importFrom shinyWidgets sliderTextInput

mod_load_data_server <- function(input, output, session, r) {
  ns <- session$ns

  # When we see a change to the input object
  # load the file.
  observeEvent(input$file, {
    if (input$overwrite) {
      r$data_old <- r$data
      r$data <- load_user_data(input$file)
      r$data <- r$data %>%
        relocate(Year, Quarter)
      r$data_undiff <- r$data
      r$flg_diff <- FALSE
    } else {
      r$data_old <- r$data
      r$data <- merge_user_data(list(r$data_undiff, load_user_data(input$file)))
      r$data <- r$data %>%
        relocate(Year, Quarter)
      r$data_undiff <- r$data
      r$flg_diff <- FALSE
    }
  })

  # Whenever the underlying data changes update the DT which displays it.
  observeEvent(r$data, {
    output$user_DT <- renderDT(r$data,
      selection = list(
        target = "column"
      ),
      options = list(
        pageLength = 5,
        lengthMenu = list(
          c(5, 15, -1),
          c("5", "15", "All")
        ),
        scrollX = TRUE,
        searching = FALSE,
        ordering = FALSE,
        pagingType = "simple"
      )
    )
  })

  # Difference the data if user selects checkbox to do so.
  observeEvent(input$diff, {
    req(r$data, r$data_undiff)
    if (input$diff) {
      # store undifferenced version so user can undo if needed
      r$data_undiff <- r$data

      # store starting values so we can inverse difference later
      r$starting_values <- r$data[1, ]

      # difference data
      r$data <- diff_df(r$data)
      r$flg_diff <- TRUE
    } else {
      r$data <- r$data_undiff
      r$starting_values <- NULL
      r$flg_diff <- FALSE
    }
  })

  # If the users hits undo revert to the previous dataset, quite crude but might
  # be useful if you make a mistake with the columns. Could be expaned to revert
  # more changes if we make data_old a list of old dataframes. One should do for
  # now.
  observeEvent(input$undo, {
    if (is.null(r$data_old)) {
      message("No operations to undo.")
    } else {
      r$data <- r$data_old
    }
  })

  # Drop columns
  observeEvent(input$drop_col, {
    req(r$data, input$user_DT_columns_selected)
    cols_to_drop <- input$user_DT_columns_selected
    if (any(c(1, 2) %in% cols_to_drop)) {
      warning("Dropping Year or Quarter is a bad idea so let's not.")
      cols_to_drop <- cols_to_drop[cols_to_drop %not_in% c(1, 2)]
    }

    r$data_old <- r$data
    r$data <- r$data %>% select(-cols_to_drop)

    r$data_undiff <- r$data_undiff %>% select(-cols_to_drop)
  })

  # Keep columns
  observeEvent(input$keep_col, {
    req(r$data, input$user_DT_columns_selected)

    cols_to_keep <- input$user_DT_columns_selected
    if (any(c(1, 2) %not_in% cols_to_keep)) {
      warning("Dropping Year or Quarter is a bad idea so let's not.")
      cols_to_keep <- union(c(1, 2), cols_to_keep)
    }

    # store a copy of the data pre-change so that user can undo one step
    r$data_old <- r$data

    # keep selected columns only
    r$data <- r$data %>% select(Year, Quarter, cols_to_keep)

    # update undifferenced copy for reference
    r$data_undiff <- r$data_undiff[, cols_to_keep]
  })

  # when user updates last period of historical data, setup end period for
  # models
  observeEvent(input$RangeHistorical, {
    req(r$data, r$dep_var)

    # read in the bounds for historical data (from user input)
    r$date_start <- yq(input$RangeHistorical[1])
    r$date_start <- c(year(r$date_start), quarter(r$date_start))
    r$date_end <- yq(input$RangeHistorical[2])
    r$date_end <- c(year(r$date_end), quarter(r$date_end))
  })

  # slider input - Historical data -----
  output$RangeHistorical <- renderUI({
    req(r$data, r$dep_var)
    df <- r$data

    # create the sequence of Date objects
    dateList <- seq(yq(paste0(
      df[1, "Year"],
      ": Q",
      df[1, "Quarter"]
    )),
    to = yq(paste0(
      df[nrow(df), "Year"],
      ": Q",
      df[nrow(df), "Quarter"]
    )),
    by = "quarter"
    )

    # format vector
    dateListFormatted <- as.yearqtr(dateList)

    # find default end for historical data
    # (based on when dependent variable ends)
    if (is.null(r$dep_var)) {
      defaultEnd <- dateListFormatted[length(dateListFormatted)]
    } else {
      # find the last data point for the selected dependent variable
      lastDepVarDataPoint <- df %>%
        select("Year", "Quarter", r$dep_var)
      lastDepVarDataPoint <- na.trim(lastDepVarDataPoint)
      lastDepVarDataPoint <- lastDepVarDataPoint[nrow(lastDepVarDataPoint), ]

      defaultEnd <- c(
        as.numeric(lastDepVarDataPoint[, "Year"]),
        as.numeric(lastDepVarDataPoint[, "Quarter"])
      )
    }

    # put together widget
    sliderTextInput(
      inputId = ns("RangeHistorical"),
      label = "Select the start and end points for the historical data",
      grid = TRUE,
      force_edges = TRUE,
      choices = dateListFormatted,
      selected = c(
        dateListFormatted[1],
        defaultEnd
      )
    )
  })

  # Download the dataframe as rds
  # TODO maybe add a csv option or swap to csv.
  output$download_data <- downloadHandler(
    filename = "uploaded_data.rds",
    content = function(file) {
      saveRDS(r$data, file)
    }
  )
}
