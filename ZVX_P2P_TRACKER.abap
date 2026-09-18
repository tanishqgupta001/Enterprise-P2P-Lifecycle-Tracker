*&---------------------------------------------------------------------*
*& Program     : ZVX_P2P_TRACKER
*& Description : Procure-to-Pay (P2P) Live Tracker Report
*& Developer   : Tanishq Gupta
*& Platform    : SAP ECC 6.0 / SAP S/4HANA
*& Tables Used : EKKO, EKPO, EKET, MSEG, RSEG, BSEG, MAKT
*& ALV Class   : CL_SALV_TABLE (OO ALV)
*&---------------------------------------------------------------------*
REPORT zvx_p2p_tracker NO STANDARD PAGE HEADING LINE-SIZE 255.

*&---------------------------------------------------------------------*
*& Type Definitions
*&---------------------------------------------------------------------*
TYPES: BEGIN OF ty_p2p,
         ebeln    TYPE ekko-ebeln,       "Purchase Order Number
         aedat    TYPE ekko-aedat,       "PO Creation Date
         lifnr    TYPE ekko-lifnr,       "Vendor Number
         bukrs    TYPE ekko-bukrs,       "Company Code
         werks    TYPE ekpo-werks,       "Plant
         ebelp    TYPE ekpo-ebelp,       "PO Line Item
         matnr    TYPE ekpo-matnr,       "Material Number
         maktx    TYPE makt-maktx,       "Material Description
         menge    TYPE ekpo-menge,       "PO Quantity
         meins    TYPE ekpo-meins,       "Unit of Measure
         netwr    TYPE ekpo-netwr,       "Net Value
         waers    TYPE ekko-waers,       "Currency
         eindt    TYPE eket-eindt,       "Scheduled Delivery Date
         wemng    TYPE eket-wemng,       "Goods Receipt Quantity (Scheduled)
         gr_menge TYPE mseg-menge,       "Actual GR Quantity (MSEG)
         bwart    TYPE mseg-bwart,       "Movement Type
         rbkp     TYPE rseg-belnr,       "Invoice Document Number
         bseg     TYPE bseg-belnr,       "FI Payment Document
         status   TYPE char50,           "P2P Status (computed)
       END OF ty_p2p.

TYPES: tt_p2p TYPE STANDARD TABLE OF ty_p2p.

*&---------------------------------------------------------------------*
*& Global Data
*&---------------------------------------------------------------------*
TABLES: ekko, ekpo.

DATA: gt_p2p   TYPE tt_p2p,
      gs_p2p   TYPE ty_p2p,
      go_salv  TYPE REF TO cl_salv_table,
      go_cols  TYPE REF TO cl_salv_columns_table,
      go_col   TYPE REF TO cl_salv_column_table,
      go_funcs TYPE REF TO cl_salv_functions_list,
      go_disp  TYPE REF TO cl_salv_display_settings,
      go_sorts TYPE REF TO cl_salv_sorts,
      gx_salv  TYPE REF TO cx_salv_msg.

*&---------------------------------------------------------------------*
*& Class Definition for Events (Hotspot Drill-Down)
*&---------------------------------------------------------------------*
CLASS lcl_event_handler DEFINITION.
  PUBLIC SECTION.
    CLASS-METHODS: on_link_click
      FOR EVENT link_click OF cl_salv_events_table
      IMPORTING row column.
ENDCLASS.

CLASS lcl_event_handler IMPLEMENTATION.
  METHOD on_link_click.
    DATA: ls_p2p   TYPE ty_p2p,
          lv_tcode TYPE tcode.

    READ TABLE gt_p2p INTO ls_p2p INDEX row.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    CASE column.
      WHEN 'EBELN'.
        lv_tcode = 'ME23N'.
        SET PARAMETER ID 'BES' FIELD ls_p2p-ebeln.
        CALL TRANSACTION lv_tcode AND SKIP FIRST SCREEN.

      WHEN 'RBKP'.
        IF ls_p2p-rbkp IS NOT INITIAL.
          lv_tcode = 'MIR4'.
          SET PARAMETER ID 'RBN' FIELD ls_p2p-rbkp.
          CALL TRANSACTION lv_tcode AND SKIP FIRST SCREEN.
        ENDIF.
    ENDCASE.
  ENDMETHOD.
ENDCLASS.

*&---------------------------------------------------------------------*
*& Selection Screen
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE t_b1.
  SELECT-OPTIONS: so_bukrs FOR ekko-bukrs OBLIGATORY,   "Company Code
                  so_werks FOR ekpo-werks,              "Plant
                  so_ekorg FOR ekko-ekorg,              "Purchasing Org
                  so_lifnr FOR ekko-lifnr,              "Vendor
                  so_aedat FOR ekko-aedat.              "PO Date Range
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE t_b2.
  PARAMETERS: p_open  AS CHECKBOX DEFAULT 'X',  "Show Open POs
              p_part  AS CHECKBOX DEFAULT 'X',  "Show Partial GR
              p_grcmp AS CHECKBOX DEFAULT 'X',  "Show GR Complete
              p_inv   AS CHECKBOX DEFAULT 'X',  "Show Invoice Posted
              p_clr   AS CHECKBOX DEFAULT 'X'.  "Show Fully Cleared
SELECTION-SCREEN END OF BLOCK b2.

*&---------------------------------------------------------------------*
*& Initialization
*&---------------------------------------------------------------------*
INITIALIZATION.
  t_b1 = 'P2P Selection Criteria'.
  t_b2 = 'P2P Status Filter'.

*&---------------------------------------------------------------------*
*& Start of Selection
*&---------------------------------------------------------------------*
START-OF-SELECTION.
  PERFORM fetch_po_data.
  PERFORM classify_status.
  PERFORM apply_status_filter.
  PERFORM display_alv.

*&---------------------------------------------------------------------*
*& FORM: fetch_po_data
*&---------------------------------------------------------------------*
FORM fetch_po_data.

  SELECT
    k~ebeln,
    k~aedat,
    k~lifnr,
    k~bukrs,
    k~waers,
    p~ebelp,
    p~werks,
    p~matnr,
    p~menge,
    p~meins,
    p~netwr,
    e~eindt,
    e~wemng,
    m~bwart,
    m~menge AS gr_menge,
    r~belnr AS rbkp
  INTO CORRESPONDING FIELDS OF TABLE @gt_p2p
  FROM ekko AS k
    INNER JOIN ekpo AS p      ON  k~ebeln = p~ebeln
    LEFT OUTER JOIN eket AS e ON  p~ebeln = e~ebeln
                              AND p~ebelp = e~ebelp
    LEFT OUTER JOIN mseg AS m ON  p~ebeln = m~ebeln
                              AND p~ebelp = m~ebelp
                              AND m~bwart = '101'
    LEFT OUTER JOIN rseg AS r ON  p~ebeln = r~ebeln
                              AND p~ebelp = r~ebelp
  WHERE k~bukrs IN @so_bukrs
    AND p~werks IN @so_werks
    AND k~ekorg IN @so_ekorg
    AND k~lifnr IN @so_lifnr
    AND k~aedat IN @so_aedat
    AND k~bstyp = 'F'
    AND p~loekz = ' '
  ORDER BY k~aedat DESCENDING,
           k~ebeln ASCENDING,
           p~ebelp ASCENDING.

  IF sy-subrc <> 0.
    MESSAGE 'No Purchase Orders found for the given selection.' TYPE 'I'.
    LEAVE LIST-PROCESSING.
  ENDIF.

  "Enrich with material descriptions
  LOOP AT gt_p2p INTO gs_p2p.
    SELECT SINGLE maktx INTO @gs_p2p-maktx
      FROM makt
      WHERE matnr = @gs_p2p-matnr
        AND spras = @sy-langu.
    MODIFY gt_p2p FROM gs_p2p.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& FORM: classify_status
*&---------------------------------------------------------------------*
FORM classify_status.

  LOOP AT gt_p2p INTO gs_p2p.

    "Check payment clearing from BSEG
    SELECT SINGLE belnr INTO @gs_p2p-bseg
      FROM bseg
      WHERE ebeln = @gs_p2p-ebeln
        AND ebelp = @gs_p2p-ebelp
        AND koart = 'K'.

    IF gs_p2p-bseg IS NOT INITIAL.
      gs_p2p-status = 'Fully Cleared'.
    ELSEIF gs_p2p-rbkp IS NOT INITIAL.
      gs_p2p-status = 'Invoice Posted'.
    ELSEIF gs_p2p-wemng >= gs_p2p-menge AND gs_p2p-wemng > 0.
      gs_p2p-status = 'GR Complete: Invoice Pending'.
    ELSEIF gs_p2p-gr_menge > 0 AND gs_p2p-gr_menge < gs_p2p-menge.
      gs_p2p-status = 'Partial GR'.
    ELSE.
      gs_p2p-status = 'PO Open: GR & Invoice Pending'.
    ENDIF.

    MODIFY gt_p2p FROM gs_p2p.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& FORM: apply_status_filter
*&---------------------------------------------------------------------*
FORM apply_status_filter.

  IF p_open = ' '.
    DELETE gt_p2p WHERE status = 'PO Open: GR & Invoice Pending'.
  ENDIF.
  IF p_part = ' '.
    DELETE gt_p2p WHERE status = 'Partial GR'.
  ENDIF.
  IF p_grcmp = ' '.
    DELETE gt_p2p WHERE status = 'GR Complete: Invoice Pending'.
  ENDIF.
  IF p_inv = ' '.
    DELETE gt_p2p WHERE status = 'Invoice Posted'.
  ENDIF.
  IF p_clr = ' '.
    DELETE gt_p2p WHERE status = 'Fully Cleared'.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& FORM: display_alv
*&---------------------------------------------------------------------*
FORM display_alv.

  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = go_salv
        CHANGING  t_table      = gt_p2p ).
    CATCH cx_salv_msg INTO gx_salv.
      MESSAGE gx_salv TYPE 'E'.
  ENDTRY.

  go_funcs = go_salv->get_functions( ).
  go_funcs->set_all( abap_true ).

  go_disp = go_salv->get_display_settings( ).
  go_disp->set_striped_pattern( cl_salv_display_settings=>true ).
  go_disp->set_list_header( 'Enterprise P2P Tracker Engine' ).

  go_cols = go_salv->get_columns( ).
  go_cols->set_optimize( abap_true ).
  go_cols->set_key_fixation( abap_true ).

  PERFORM set_column USING:
    'EBELN'    'PO Number'       abap_true,
    'EBELP'    'Item'            abap_true,
    'AEDAT'    'PO Date'         abap_false,
    'LIFNR'    'Vendor'          abap_false,
    'BUKRS'    'Co. Code'        abap_false,
    'WERKS'    'Plant'           abap_false,
    'MATNR'    'Material'        abap_false,
    'MAKTX'    'Description'     abap_false,
    'MENGE'    'PO Qty'          abap_false,
    'MEINS'    'UoM'             abap_false,
    'NETWR'    'Net Value'       abap_false,
    'WAERS'    'Currency'        abap_false,
    'EINDT'    'Delivery Date'   abap_false,
    'GR_MENGE' 'GR Qty'          abap_false,
    'RBKP'     'Invoice Doc'     abap_false,
    'STATUS'   'P2P Status'      abap_false.

  TRY.
      go_col ?= go_cols->get_column( 'EBELN' ).
      go_col->set_cell_type( if_salv_c_cell_type=>hotspot ).
      go_col ?= go_cols->get_column( 'RBKP' ).
      go_col->set_cell_type( if_salv_c_cell_type=>hotspot ).
    CATCH cx_salv_not_found.
  ENDTRY.

  DATA lo_events TYPE REF TO cl_salv_events_table.
  lo_events = go_salv->get_event( ).
  SET HANDLER lcl_event_handler=>on_link_click FOR lo_events.

  go_sorts = go_salv->get_sorts( ).
  TRY.
      go_sorts->add_sort( columnname = 'AEDAT' sequence = if_salv_c_sort=>sort_down ).
    CATCH cx_salv_not_found cx_salv_existing cx_salv_data_error.
  ENDTRY.

  go_salv->display( ).

ENDFORM.

*&---------------------------------------------------------------------*
*& FORM: set_column
*&---------------------------------------------------------------------*
FORM set_column USING pv_col   TYPE lvc_fname
                      pv_label TYPE string
                      pv_key   TYPE abap_bool.
  DATA: lv_long   TYPE scrtext_l,
        lv_medium TYPE scrtext_m,
        lv_short  TYPE scrtext_s.

  lv_long   = pv_label.
  lv_medium = pv_label.
  lv_short  = pv_label.

  TRY.
      go_col ?= go_cols->get_column( pv_col ).
      go_col->set_long_text(   lv_long ).
      go_col->set_medium_text( lv_medium ).
      go_col->set_short_text(  lv_short ).
      IF pv_key = abap_true.
        go_col->set_key( abap_true ).
      ENDIF.
    CATCH cx_salv_not_found.
  ENDTRY.
ENDFORM.
