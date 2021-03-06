

# This is the server logic for a Shiny web application.
# You can find out more about building applications with Shiny here:
#
# http://shiny.rstudio.com
#

shinyServer(function(input, output, session) {

  # Wait for sessionInitialized to load packages. This does not have to be defined
  # in your UI, as the input will be passed via Shiny.onInputChange()
  observeEvent(input$sessionInitialized, {
    source("deferred.R")
    # After packages loaded, run button transform to signal ready states
    runjs("handlers.initGetStarted();")
  }, ignoreNULL = TRUE, ignoreInit = TRUE, once = TRUE)

  ################################################
  #                                              #
  #          Define reactive variables           #
  #                                              #
  ################################################

  # Reactive Values for Metabolite Data. These are isolated into individual
  # reactive values so we can depend on them for reactive changes
  metaboliteObject <- reactiveVal()
  mappedMetabolites <- reactiveVal()
  mappingObject <- reactiveVal()
  mappingSummary <- reactiveValues(table = NULL, dbChosen = NULL)
  mappedMetaboliteTable <- reactiveVal()
  preSelectedIDType <- reactiveVal()
  databaseChosen <- reactiveVal()
  selectedMetab <- reactiveVal()
  idTypeChosen <- reactiveVal()
  columnPicked <- reactiveVal()
  hmdbCol <- reactiveVal()

  ################################################
  #                                              #
  #            Welcome Tab Handlers              #
  #                                              #
  ################################################

  # When clicking "Get Started", switch to Upload panel
  observeEvent(input$getStarted, {
    updateNavbarPage(session, inputId = "navbarLayout", selected = "uploadPanel")
  }, ignoreInit = TRUE)

  # When clicking "Tutoria", switch to tutorial panel
  observeEvent(input$tutorial, {
    updateNavbarPage(session, inputId = "navbarLayout", selected = "tutorialPanel")
  }, ignoreInit = TRUE)

  ################################################
  #                                              #
  #            Upload Tab Handlers               #
  #                                              #
  ################################################

  ## Inject example df when "Try Examples" selected
  observeEvent(input$tryExamples, {
    # input examples
    metaboliteObject(examples)
    # and wipe mapping objects
    mappingObject(NULL)
    mappedMetabolites(NULL)
    mappingObject(NULL)
    mappingSummary$table <- NULL
    mappingSummary$dbChosen <- NULL
    mappedMetaboliteTable(NULL)
    databaseChosen(NULL)
  }, ignoreInit = TRUE, ignoreNULL = TRUE)

  ## Read CSV when any of (fileInput, checkboxInput, radioButtons) states change
  observeEvent({
    input$metaboliteUpload
    input$sep
    input$header
  }, {
    if (!is.null(input$metaboliteUpload)) {
      read_delim(
        file = input$metaboliteUpload$datapath,
        col_names = input$header,
        delim = input$sep
      ) %>% metaboliteObject() # and save to the reactiveVal
      # Also wipe mapping objects
      mappingObject(NULL)
      mappedMetabolites(NULL)
      mappingObject(NULL)
      mappingSummary$table <- NULL
      mappingSummary$dbChosen <- NULL
      mappedMetaboliteTable(NULL)
      databaseChosen(NULL)
    }
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  # Unfortunately, this does not work :(
  # Once we have the table, check the header to see if there's an HMDB column
  # observeEvent({
  #   metaboliteObject()
  # }, {
  #   # get the index of a column which is labeled 'hmdb'
  #   indexOfHMDB <- which(tolower(colnames(metaboliteObject())) == 'hmdb')
  #   # If we got an answer back, lower the index by one (as DT indexes by zero),
  #   # and assign to a reactive variable
  #   if (!identical(indexOfHMDB, integer(0))) {
  #     indexOfHMDB <- indexOfHMDB - 1
  #     hmdbCol(indexOfHMDB)
  #   }
  # })

  ## Once data is populated, render help text to user
  output$uploadSuccess <- renderUI({
    input$tryExamples # make sure the try examples button is a dependency
    if (is.null(metaboliteObject())) {
      return(NULL)
    }
    tags$p(
      class = "conditional-help",
      "Check below to see that your data has been uploaded properly.  ",
      "If so, click a column and ID type and proceed to the 'Map' tab!"
    )
  })

  ## Once data is populated, render preview of data to user
  output$uploadedDataTable <- DT::renderDataTable({
    input$tryExamples
    input$sep
    input$header
    input$metaboliteUpload
    if (is.null(metaboliteObject())) {
      # Return null if nothing so that we don't pass an error
      return(NULL)
    } else {
      # Render the (reactive value) uploadedDataTable
      metaboliteObject()
    }
    # DataTables options
  },
  options = list(
    pageLength = 10,
    lengthMenu = c(5, 10, 15, 20),
    # autoWidth = TRUE,
    scrollX = "100%",
    # AMAZING! Crucial argument to make sure DT doesn't overflow
    # vertical scrolling options
    scrollY = "450px",
    scrollCollapse = TRUE,
    paging = FALSE
  ),
  rownames = FALSE,
  selection = list(
    mode = "single", target = "column",
    selected = 0
  ),
  style = "bootstrap",
  class = "table-bordered table-responsive"
  )

  output$uploadedTablePanel <- renderUI({
    tags$div(
      class = "col-sm-9",
      uiOutput("uploadSuccess"),
      dataTableOutput("uploadedDataTable") # %>% withSpinner(type = 8, color = '#303E4E')
    )
  })

  observeEvent({
    input$uploadedDataTable_columns_selected
    metaboliteObject()
  }, {
    # wait 500ms after panel render and re-activate tooltips
    runjs("setTimeout(() => { handlers.activateTooltips(['.panel-tooltip', '.btn-tooltip']); }, 100)")
  })

  # This has to be rendered separately from the column picker panel. Otherwise,
  # the entire column picker panel has to be re-rendered when the preselected ID
  # type gets updated, which resets the entire panel, which reverts to the
  # preselected column, effectively making it impossible to switch columns!
  output$idSelector <- renderUI({
    tags$div(
      selectInput(
        "idType",
        "ID Type",
        width = "50%",
        choices = c("HMDB", "KEGG", "PubChem", "CAS", "MetaCyc Object ID" = "Compound"),
        selected = preSelectedIDType(),
        selectize = FALSE
      ),
      # Include button to proceed.
      actionButton(
        inputId = "continueToMap",
        label = "Proceed",
        class = "btn-med btn-tooltip",
        title = "Proceed to mapping your metabolites",
        `data-position` = "right"
      )
    )
  })

  # Render the UI for the column picker panel
  columnPickerUI <- eventReactive({
    # Change on button click (upload/examples)
    input$tryExamples
    input$metaboliteUpload
    # OR on header change
    input$sep
    input$header
  }, {
    # Only render if NOT NULL
    if (!is.null(metaboliteObject())) {
      tags$form(
        class = "well",
        # Dynamically render the idType selector panel here (see below) This is
        # intentionally separate to that we do not have a feedback loop that
        # triggers re-rendering. Otherwise, as soon as you change this value,
        # the entire panel re-renders, switching it back to its default.
        uiOutput("idSelector")
      )
    }
  })

  observeEvent(input$uploadedDataTable_columns_selected, {
    # DataTables indexes by 0, so we add one
    columnIndex <- input$uploadedDataTable_columns_selected + 1
    # Then pick the column name!
    columnName <- colnames(metaboliteObject())[columnIndex]
    columnPicked(columnName)
  })

  # When data is populated, show column picker panel for users to select. This
  # is separate from the actual code to render so that we can only depend on
  # specific events triggering re-renders.
  output$columnPickerPanel <- renderUI({
    columnPickerUI()
  })

  # If the selected ID type is a column name in the DF, preselect that
  observeEvent(columnPicked(), {
    if (tolower(columnPicked()) %in% c("cas", "pubchem", "hmdb", "kegg")) {
      preSelectedIDType(columnPicked())
    }
  },
  ignoreNULL = TRUE,
  ignoreInit = TRUE
  )

  ## Switch to Map panel when "Proceed" is clicked on Upload tab
  observeEvent(input$continueToMap, {
    updateNavbarPage(session, inputId = "navbarLayout", selected = "mapPanel")
  }, ignoreInit = TRUE)

  ################################################
  #                                              #
  #                Map Tab Handlers              #
  #                                              #
  ################################################

  # Store ID type chosen as reactive variable which only changes when the map button is clicked
  observeEvent(input$mapButton, {
    idTypeChosen(input$idType)
  })

  ## Here's where the heavy lifting takes place!!
  ## We now take the columns the user specified and map them to genes!
  ## Even better, now that we have a UI, we can choose

  # when the map button is clicked, update the dbChosen.
  observeEvent(input$mapButton, {
    # Run JS to clear table content
    # runjs('handlers.clearMappingTables();') # do not clear by setting innerHTML!
    # change the dbChosen reactive Value
    databaseChosen(input$dbChosen)
    # Clear any pre-existing alerts
    removeUI(selector = "#mappingAlert")
    # Conduct the mapping from our mapGenerally() function defined in mapGenerally.R
    mappingOutput <- mapGenerally(
      importDF = metaboliteObject(),
      col = columnPicked(),
      db = databaseChosen(),
      idType = idTypeChosen()
    )
    # Assign the mapped data to our reactive value
    mappedMetabolites(mappingOutput$data)
    # and assign the full object so we can access the status reports later
    mappingObject(mappingOutput)
    # Create new alert bubble with status message
    # Add optional tweet link? Or email link with error message?
    mappingAlert(
      status = mappingOutput$status,
      message = mappingOutput$message,
      suggest = mappingOutput$suggest
    )
  }, ignoreInit = TRUE)

  ###############################################################
  #                                                             #
  # Interlude: Change ID Type to KEGG if KEGG DB is being used. #
  # Otherwise, continue to use input ID type                    #
  #                                                             #
  ###############################################################

  # idTypeOfInterest <- reactiveVal()
  #
  # observeEvent(input$mapButton, {
  #   if (databaseChosen() == 'KEGG') {
  #     idTypeOfInterest('KEGG')
  #   } else {
  #     idTypeOfInterest(input$idType)
  #   }
  # })

  ############################# End ##############################

  # THREE STEP RENDER PROCESS
  # 1. Generate Table from `generateTables.R::generateSummaryTable()`, depending
  #    only on the mapButton click.
  # 2. Render the generated table with DR::renderDataTable(). This is separate
  #    from #1 because we need to assign the reactive table object to its own
  #    output Object.
  # 3. Render the entire UI surrounding the table and insert the rendered DT.

  ## STEP ONE
  # ~~~~~~~~~~
  # Show a summary table of the mapped metabolites (just # of genes)
  # This calls generateSummaryTable() from generateTables.R
  # We should make this optional!
  # Only render when 'map' clicked
  observeEvent(input$mapButton, {
    # create the summary tables
    results <- generateSummaryTable(mappingObject(), idTypeChosen(), databaseChosen())
    mappingSummary$table <- results$table
    mappingSummary$dbChosen <- results$dbChosen
  })

  ## STEP TWO
  # ~~~~~~~~~~
  # Once metabolites have been mapped, render the results!
  output$mappingSummaryTable <- DT::renderDataTable({
    mappingSummary$table %>% hyperlinkTable(databaseChosen())
  },
  rownames = FALSE,
  style = "bootstrap",
  class = "table-bordered table-responsive compact",
  escape = FALSE,
  selection = "single"
  )

  ## STEP THREE
  # ~~~~~~~~~~
  # Render the panel separately so we have reactive control over all the UI
  # elements surrounding the DataTable, not just the dataTable
  output$mappingSummaryPanel <- renderUI({
    # make sure this depends on the summary table
    # (and thus updates every time the summary table does)
    mappingSummary$table
    # Now proceed...
    if (is.null(mappingObject())) {
      return(NULL)
    } else if (mappingObject()$status == "error" | mappingObject()$status == "empty") {
      return(NULL)
      # Only render if we had non-null, non-error, non-empty results
    } else {
      return(
        tagList(
          tags$h3(paste0("Mapping Summary - ", databaseChosen()), class = "tab-header"),
          # Insert the datatable here that we rendered above.
          DT::dataTableOutput("mappingSummaryTable")
        )
      )
    }
  })

  # When a new metabolite is selected, set it to the selected metabolite reactive value!
  # Why? So we can reset it given other certain conditions (see the next function)
  observeEvent(input$mappingSummaryTable_rows_selected, {
    selectedMetab(input$mappingSummaryTable_rows_selected)
  })

  # But when the map button is selected, nullify any previously selected metabolite
  observeEvent(input$mapButton, {
    selectedMetab(NULL)
  })


  # THREE STEP RENDER PROCESS
  # 1. Generate Table from `generateTables.R::generateSummaryTable()`, depending
  #    only on the mapButton click.
  # 2. Render the generated table with DT::renderDataTable(). This is separate
  #    from #1 because we need to assign the reactive table object to its own
  #    output Object.
  # 3. Render the entire UI surrounding the table and insert the rendered DT.

  ## STEP ONE
  ## Generate table
  ## ~~~~~~~~~~
  # Now, show the filtered (unsummarized) table, based on what metabolite user clicked on.
  observeEvent({
    # When we select a new metabolite in the summary table...
    selectedMetab()
    # When we click the map button... (this is important because we need to be
    # able to update in case there are errors we need to display)
    input$mapButton
  }, {
    # Pull the $data object from the tryCatch output if there was an error. This
    # should default to the previous successful step.
    if (mappingObject()$status == "error" |
      mappingObject()$status == "empty") {
      mappingObject()$data %>% mappedMetaboliteTable()

      # Also make sure our mapping was actually conducted
      # Sometimes the click doesn't register??
      # Use DOM API here to read header
      # } else if () {

      # Otherwise, generate our table depending on the chosen database! As with
      # `generateSummaryTable()`, these functions come from `generateTables.R`
    } else if (databaseChosen() == "KEGG") {
      if (mappingSummary$dbChosen != "KEGG") {
        # if our summary table was somehow not updated yet, exit
        return(NULL)
      } else {
        generateKEGGMetabTable(
          mappingObject(),
          mappingSummary$table,
          selectedMetab(),
          idTypeChosen()
        ) %>% mappedMetaboliteTable()
        # otherwise proceed with generated the metab table
      }
    } else if (databaseChosen() == "MetaCyc") {
      # if our summary table was somehow not updated yet, exit
      if (mappingSummary$dbChosen != "MetaCyc") {
        return(NULL)
        # otherwise proceed with generated the metab table
      } else {
        generateMetaCycMetabTable(
          mappingObject(),
          mappingSummary$table,
          selectedMetab(),
          idTypeChosen()
        ) %>% mappedMetaboliteTable()
      }
    }
  })

  ## STEP TWO
  ## Render generated table
  ## ~~~~~~~~~~
  # Once metabolites have been mapped, render the results!
  output$mappedMetaboliteTable <- DT::renderDataTable({
    if (is.null(mappingObject()) | is.null(selectedMetab())) {
      return(data.frame())
    } else if (mappingObject()$status == "success") {
      # Only render if we had non-null, non-error, non-empty results
      mappedMetaboliteTable() %>% hyperlinkTable(databaseChosen())
    }
  },
  rownames = FALSE,
  style = "bootstrap",
  class = "table-bordered table-responsive compact",
  escape = FALSE,
  selection = "single"
  )

  ## STEP THREE
  ## Render entire UI output, including the rendered table
  # ~~~~~~~~~~
  output$fullMappingResultsPanel <- renderUI({
    tags$div(
      if (is.null(mappingObject())) {
        return(NULL)
        # If we had an error, change the header to reflect that these are intermediate results
      } else if (
        mappingObject()$status == "error" | mappingObject()$status == "empty"
      ) {
        tags$h3("Intermediate Results")
        # Only render if we had non-null, non-error, non-empty results
      } else {
        tags$h3("Per-Metabolite Mapping Results")
      },
      # Rendered table from STEP TWO goes here!
      DT::dataTableOutput("mappedMetaboliteTable")
    )
  })

  ## Watch for the "try again" button that will be rendered if an error occurs in mapping
  observeEvent(input$remap, {
    updateNavbarPage(session, inputId = "navbarLayout", selected = "uploadPanel")
  }, ignoreInit = TRUE, ignoreNULL = TRUE)

  ## Once table exists, render save panel
  output$saveMappingPanel <- renderUI({
    if (!is.null(mappedMetabolites())) {
      tags$form(
        class = "well",
        tags$p("Download a copy of your full mapping results. "),
        radioButtons(
          "saveType",
          "Download Results",
          choices = c(
            "Comma-Separated Values" = "csv",
            "Tab-Separated Values" = "tsv"
          ),
          selected = "csv"
        ),
        # With a tooltip
        downloadButton(
          "downloadMappingData",
          "Download",
          class = "btn-med btn-tooltip",
          title = "Download your full mapping results"
          # `data-toggle` = "btn-tooltip",
          # `data-placement` = "right",
          # `data-original-title` = "Download your full mapping results."
        )
      )
    }
  })

  # Navigate to Viz page when KEGG was chosen

  ##############################################
  #                                            #
  #      UPDATE TO REMOVE DISABLED BUTTON      #
  #       It's simply bad user experience      #
  #                                            #
  ##############################################

  output$continueToViz <- renderUI({
    # Do not render panel if no db has been mapped against yet (because
    # databaseChosen does not get input$dbChosen until "mapButton" is clicked)
    if (is.null(databaseChosen())) {
      return(NULL)
      # once mapped, render the panel
    } else if (databaseChosen() == "MetaCyc") {
      return(NULL)
    } else {
      tags$form(
        class = "well",
        tags$label("Visualize Results"),
        tags$p(
          "If you mapped against KEGG, you have the option",
          "to visualize your results with pathview."
        ),
        br(),
        # If we mapped against KEGG, show visualize button
        if (databaseChosen() == "KEGG" &
          !is.null(selectedMetab())) {
          actionButton(
            inputId = "visualizeButton",
            label = "Visualize",
            class = "btn btn-med btn-tooltip",
            title = "Visualize your results with pathview"
          )
          # But if we mapped against MetaCyc, we don't have visualizations for
          # this yet, so disable the viz button
        } else {
          actionButton(
            inputId = "visualizeButton",
            label = "Visualize",
            class = "btn btn-med btn-tooltip disabled",
            title = "Select a metabolite from the summary table"
          )
        }
      )
    }
  })

  # Client-side JS to enable/disable viz tab!
  # Also disable viz tab in navbar when viz mapping is not possible
  # Make sure that we have a tooltip explaining why the viz tab is disabled as well
  observeEvent(input$mapButton, {
    if (databaseChosen() == "KEGG" & !is.null(selectedMetab())) {
      runjs("$(\"a[data-value='vizPanel']\").parent().removeClass('disabled');")
      runjs("$(\"a[data-value='vizPanel']\").removeClass('panel-tooltip');")
    } else {
      runjs("$(\"a[data-value='vizPanel']\").parent().addClass('disabled');")
      runjs("$(\"a[data-value='vizPanel']\").addClass('panel-tooltip');")
    }
  })

  # Client-side JS to enable/disable viz tab!
  observeEvent(input$mappingSummaryTable_rows_selected, {
    if (databaseChosen() == "KEGG" & !is.null(selectedMetab())) {
      runjs("$(\"a[data-value='vizPanel']\").parent().removeClass('disabled');")
      runjs("$(\"a[data-value='vizPanel']\").removeClass('panel-tooltip');")
    } else {
      runjs("$(\"a[data-value='vizPanel']\").parent().addClass('disabled');")
      runjs("$(\"a[data-value='vizPanel']\").addClass('panel-tooltip');")
    }
  })

  # When clicking "Visualize", switch to Visualize panel
  observeEvent(input$visualizeButton, {
    updateNavbarPage(session, inputId = "navbarLayout", selected = "vizPanel")
  }, ignoreInit = TRUE)

  ## Export data
  output$downloadMappingData <- downloadHandler(
    # Name file: `originalFilename_mapped_dbChosen.savetype`
    filename = function() {
      paste0(
        ifelse(
          test = is.null(input$metaboliteUpload),
          yes = "example_dataset",
          no = tools::file_path_sans_ext(input$metaboliteUpload$name)
        ),
        "_mapped_",
        databaseChosen(),
        ".",
        input$saveType
      )
    },
    content = function(file) {
      write_delim(
        mappedMetabolites(),
        file,
        delim = switch(
          input$saveType,
          "csv" = ",",
          "tsv" = "\t"
        )
      )
    }
  )
  ################################################
  #                                              #
  #                Viz Tab Handlers              #
  #                                              #
  ################################################

  # Set up reactive values for:
  # - The selected compound of the clicked row
  # - The pathways that compound is involved in
  # - The genes (for the enzymes) that compound interacts with
  selectedRowAttrs <- reactiveValues(
    "selectedCompound" = NULL,
    "selectedCompoundName" = NULL,
    "pathwaysOfSelectedCompound" = NULL,
    "genesOfSelectedCompound" = NULL
  )

  # Now, when the selected row changes...
  observeEvent(input$mappingSummaryTable_rows_selected, {

    # Map!
    pathwayMappingAttrs <- generalPathwayMapping(
      summaryTable = mappingSummary$table,
      # The full table provided used to be the table that was rendered just for
      # the selected metabolites. This means that the only genes were those
      # identified for the selected metabolites. For now, I have fixed this by
      # including all genes in the mapping. HOWEVER, in the future it could be
      # interesting to create a toggle that would let the user specify which
      # they would prefer. In that case, we would have to make sure that
      # mappedMetaboliteTable() was updated before the pathway mapping function
      # was called
      # fullTable = mappedMetaboliteTable(),
      fullTable = mappingObject()$data,
      idType = idTypeChosen(),
      db = databaseChosen(),
      selectedRow = selectedMetab()
    )

    ### Assign results to their reactive values
    selectedRowAttrs$selectedCompound <-
      pathwayMappingAttrs$selectedCompound
    selectedRowAttrs$selectedCompoundName <-
      pathwayMappingAttrs$selectedCompoundName
    selectedRowAttrs$genesOfSelectedCompound <-
      pathwayMappingAttrs$genesOfSelectedCompound
    selectedRowAttrs$pathwaysOfSelectedCompound <-
      pathwayMappingAttrs$pathwaysOfSelectedCompound
  })

  # Render the pathway panel once
  output$pathwayPanel <- renderUI({
    ## Check for results before rendering!
    if (nrow(selectedRowAttrs$pathwaysOfSelectedCompound) == 0) {
      tags$div(
        tags$h4(
          paste0(
            "Pathways for ",
            selectedRowAttrs$selectedCompoundName
          )
        ),
        tags$p("No pathways found for this compound.")
      )
    } else if (databaseChosen() == "KEGG") {
      tags$div(
        tags$h4(paste0(
          "Pathways for ",
          selectedRowAttrs$selectedCompoundName
        )),
        selectInput(
          inputId = "pathwaysPicked",
          label = "Pathway",
          choices = selectedRowAttrs$pathwaysOfSelectedCompound$namedPway,
          selectize = FALSE
        ),
        tags$p("Each pathway may take some time to process."),
        tags$p(
          "For each pathway, only the compound selected ",
          "is shown, but ALL mapped genes are shown."
        )
      )
    } else if (databaseChosen() == "MetaCyc") {
      tags$div(
        tags$h4(paste0(
          "Pathways for ",
          selectedRowAttrs$selectedCompoundName
        )),
        selectInput(
          inputId = "pathwaysPicked",
          label = "Pathway",
          choices = selectedRowAttrs$pathwaysOfSelectedCompound$pathwayName,
          selectize = FALSE
        )
      )
    }
  })

  output$pathwayView <- renderImage({
    if (is.null(input$pathwaysPicked)) {
      return({
        list(
          src = "./logo_background.svg",
          contentType = "image/svg",
          width = 512,
          height = 512,
          alt = "pathway placeholder"
        )
      })
    }

    # Setup named variables for standard eval
    pathwayNameIDcol <- as.name("namedPway")
    selectedPathway <- rlang::quo(input$pathwaysPicked)

    # Pull the pathway ID from the pathway name selected by the user
    selectedPathwayID <-
      selectedRowAttrs$pathwaysOfSelectedCompound %>%
      dplyr::filter(rlang::UQ(pathwayNameIDcol) == input$pathwaysPicked) %>%
      extract2("id")

    filename <- visualizePathview(
      pathway = selectedPathwayID,
      genes = selectedRowAttrs$genesOfSelectedCompound,
      cpd = selectedRowAttrs$selectedCompound
    )

    # Return a list containing the filename
    # Render Image at 1000px and then constrain image to div in CSS
    return(list(
      src = filename,
      contentType = "image/png",
      width = 1000,
      # height = imageHeight(),
      alt = paste0("Pathway map of KEGG Pathway ", input$pathwaysPicked)
    ))
  }, deleteFile = TRUE)

  ## Render entire UI for vizPanel

  output$vizPanelUI <- renderUI({
    if (is.null(databaseChosen())) {
      tags$div(
        tags$h2("Pathway View", class = "tab-header"),
        # Nothing to map alert
        tags$div(
          class = "alert alert-dismissible alert-danger",
          tags$button(
            HTML("&times;"),
            type = "button",
            class = "close",
            `data-dismiss` = "alert"
          ),
          "There is nothing selected to map!"
        )
      )
    } else if (databaseChosen() == "MetaCyc") {
      tags$div(
        tags$h2("Pathway View", class = "tab-header"),
        # Nothing to map alert
        tags$div(
          class = "alert alert-dismissible alert-danger",
          tags$button(
            HTML("&times;"),
            type = "button",
            class = "close",
            `data-dismiss` = "alert"
          ),
          "You must map via KEGG to visualize your results with pathview!"
        )
      )
    } else if (is.null(selectedMetab())) {
      tags$div(
        tags$h2("Pathway View", class = "tab-header"),
        # Nothing to map alert
        tags$div(
          class = "alert alert-dismissible alert-danger",
          tags$button(
            HTML("&times;"),
            type = "button",
            class = "close",
            `data-dismiss` = "alert"
          ),
          "You must select a metabolite to visualize your results with pathview!"
        )
      )
    } else {
      tags$div(
        # Manual Sidebar
        tags$div(
          class = "col-sm-3 manual-sidebar",
          # Allow user to pick which pathway that the selected
          # metabolite participates in to view
          tags$form(
            class = "well",
            uiOutput("pathwayPanel")
          )
        ),
        # Pathway visualization
        tags$div(
          class = "col-sm-9",
          tags$h2("Pathway View", class = "tab-header"),
          imageOutput("pathwayView") %>% withSpinner(type = 8, color = "#303E4E")
        )
      )
    }
  })
})
