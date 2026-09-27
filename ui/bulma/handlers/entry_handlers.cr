# SPDX-License-Identifier: AGPL-3.0-or-later

module Document
  module Ui
    # « Saisir l'écriture » (ADR-005 D8) : saisie d'une facture d'achat avec
    # l'image du justificatif à côté, préremplie par
    # `Document::Api.purchase_prefill`. Reprend l'écran de saisie de
    # l'interface (`PartiduoUi::EntryScreen`, lignes et retour instantané
    # `ui/entries/_line.html`, `ui/entries/_check.html`) ; l'enregistrement
    # passe par `Document::Api.post_purchase`, qui enregistre une facture
    # reçue hors plateforme (numéro de la facture du fournisseur obligatoire,
    # contrôle de doublon, ADR-004 D9) et cite le justificatif comme pièce
    # jointe et source de l'écriture : l'abonnement à `entry.posted` le fait
    # passer en « Rattaché ».
    module EntryScreenMethods
      alias Api = Document::Api
      alias Acc = Partiduo::Api::Accounting

      # Facture reçue saisie : l'écriture et le numéro de la facture du
      # fournisseur (champ `invoice_number`), datée du justificatif.
      def received_input(document : Acc::DocumentInput, receipt : Api::ReceiptView) : Acc::ReceivedInvoiceInput
        Acc::ReceivedInvoiceInput.new(document: document, number: field("invoice_number").strip, invoice_date: receipt.date)
      end

      # Erreurs du contrat : numéro de la facture sous son champ, pièce
      # jointe et fournisseur de la facture reçue en tête, le reste à
      # l'écriture.
      def add_received_errors(form : PartiduoUi::EntryForm, errors : Array(Partiduo::Api::FieldError),
                              number_errors : Array(String)) : Nil
        errors.each do |error|
          case error.field
          when "number"                              then number_errors << fmt.message(error)
          when "attachment_id", "platform_reference" then form.add_error("base", fmt.message(error))
          else                                            form.add_error(error.field, fmt.message(error))
          end
        end
      end

      def default_kind : String
        "purchase"
      end

      def receipt_id : Int64
        id_param
      end

      def title : String
        I18n.t("document_ui.entry.title")
      end

      # Ventilation analytique : depuis la consultation de l'écriture.
      def analytic_choices : PartiduoUi::EntryAnalytic::Choices?
        nil
      end
    end

    class EntryHandler < PartiduoUi::EntryScreen
      include EntryScreenMethods

      def get
        require!("ACCOUNTING", PERMISSION)
        receipt = Api.receipt(current.actor, receipt_id)
        return go(Ui.url("show", receipt.id)) unless receipt.to_process? && receipt.source != "einvoice"
        vat_rate = request.query_params.has_key?("vat_rate") ? query("vat_rate") : nil
        prefill = Api.purchase_prefill(current.actor, receipt.id, vat_rate)
        form = PartiduoUi::EntryForm.new("purchase")
        prefill.lines.each_with_index do |line, index|
          form.lines << PartiduoUi::EntryForm::Line.new(index, "purchase", label: line.label,
            amount: line.amount.zero? ? "" : fmt.amount(line.amount, 2, group: false), vat_rate: line.vat_rate || "")
        end
        form.add_line
        form.ledger_id = prefill.ledger_id.try(&.to_s) || ""
        form.date = fmt.date(prefill.date)
        form.third_party = prefill.third_party
        form.label = prefill.label
        render_entry(receipt, form, vat_rate || prefill.lines.first?.try(&.vat_rate) || "", invoice_number: prefill.number)
      end

      def post
        require!("ACCOUNTING", PERMISSION)
        receipt = Api.receipt(current.actor, receipt_id)
        form = PartiduoUi::EntryForm.read("purchase", form_values)
        number = field("invoice_number").strip
        if field("add_line") == "1"
          form.add_line
          return render_entry(receipt, form, invoice_number: number)
        end
        if index = field("remove_line").to_i?
          form.remove_line(index)
          return render_entry(receipt, form.renumber!, invoice_number: number)
        end
        input = entry_input(form)
        unless input.is_a?(Partiduo::Api::Accounting::DocumentInput)
          return render_entry(receipt, form, status: 422, invoice_number: number)
        end
        result = Api.post_purchase(current.actor, receipt.id, received_input(input, receipt))
        if view = result.value?
          flash["success"] = I18n.t("document_ui.flash.posted", receipt: view.receipt.presence || view.number)
          return go(Ui.url("index"))
        end
        number_errors = [] of String
        add_received_errors(form, result.errors, number_errors)
        render_entry(receipt, form, status: 422, invoice_number: number, number_errors: number_errors)
      end

      private def render_entry(receipt : Api::ReceiptView, form : PartiduoUi::EntryForm, vat_rate : String = "",
                               status : Int32 = 200, invoice_number : String = "",
                               number_errors : Array(String) = [] of String) : Marten::HTTP::Response
        receipt_card = Ui::ReceiptCard.new(receipt, fmt)
        context["title"] = title
        context["crumbs"] = [crumb("core.menu.entry"),
                             PartiduoUi::Screen::Crumb.new(I18n.t("document.menu.document_inbox"), Ui.url("index")),
                             PartiduoUi::Screen::Crumb.new(receipt_card.title, Ui.url("show", receipt.id)),
                             PartiduoUi::Screen::Crumb.new(title)]
        context["form"] = decorate(form)
        context["kind"] = "purchase"
        context["no_ledger"] = writable_ledgers.empty?
        context["analytic_warning"] = analytic_warning?
        context["form_action"] = request.path
        context["receipt"] = receipt_card
        context["receipt_amount"] = receipt.amount.try { |value| fmt.amount(value) }
        context["receipt_supplier"] = receipt.supplier_code.empty? ? receipt.supplier_name.presence : nil
        context["vat_choices"] = vat_options(vat_rate)
        context["check_url"] = Ui.url("entry_check", receipt.id)
        context["invoice_number"] = invoice_number
        context["invoice_number_errors"] = number_errors.empty? ? nil : number_errors
        page("document/entry.html", status: status)
      end
    end

    # Retour instantané de la saisie (HTMX) : totaux et écriture calculée par
    # `Document::Api.check_purchase`, écart avec le montant du justificatif.
    class EntryCheckHandler < PartiduoUi::EntryScreen
      include EntryScreenMethods

      def post
        require!("ACCOUNTING", PERMISSION)
        receipt = Api.receipt(current.actor, receipt_id)
        form = PartiduoUi::EntryForm.read("purchase", form_values)
        check = PartiduoUi::EntryCheck.new(fmt)
        gap = nil
        number_errors = [] of String
        if (input = entry_input(form)).is_a?(Partiduo::Api::Accounting::DocumentInput)
          result = Api.check_purchase(current.actor, receipt.id, received_input(input, receipt))
          # Numéro encore vide : l'écriture calculée s'affiche quand même.
          errors = result.errors.reject do |error|
            error.key == "accounting.errors.received_invoice.number.blank" && field("invoice_number").strip.empty?
          end
          view = result.value? || (errors.empty? ? Acc.check_document(current.actor, input).value? : nil)
          if view
            check.draft(view, document: true)
            amount = receipt.amount
            if amount && view.total_including_vat != amount
              gap = fmt.amount((view.total_including_vat - amount).abs)
            end
          end
          add_received_errors(form, errors, number_errors)
        end
        list = messages(form).try(&.dup) || [] of String
        list.concat(number_errors)
        check.errors = list.empty? ? nil : list
        check.date_hint = form.date_hint
        check.due_date_hint = form.due_date_hint
        render("document/_entry_check.html", {"check" => check, "kind" => "purchase", "gap" => gap,
                                              "receipt_amount" => receipt.amount.try { |value| fmt.amount(value) }})
      end

      private def messages(form : PartiduoUi::EntryForm) : Array(String)?
        list = [] of String
        {form.base_errors, form.ledger_id_errors, form.date_errors, form.receipt_errors, form.third_party_errors,
         form.due_date_errors, form.label_errors}.each { |items| items.try { |values| list.concat(values) } }
        form.lines.each_with_index do |line, position|
          line.errors.try(&.each { |message| list << I18n.t("ui.entries.line_error", line: position + 1, message: message) })
        end
        list.empty? ? nil : list
      end
    end
  end
end
