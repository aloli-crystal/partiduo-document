# SPDX-License-Identifier: AGPL-3.0-or-later

module Document
  module Ui
    # « Saisir l'écriture » (ADR-005 D8) : saisie d'une facture d'achat avec
    # l'image du justificatif à côté, préremplie par
    # `Document::Api.purchase_prefill`. Reprend l'écran de saisie de
    # l'interface (`PartiduoUi::EntryScreen`, lignes et retour instantané
    # `ui/entries/_line.html`, `ui/entries/_check.html`) ; l'enregistrement
    # passe par `Document::Api.post_purchase`, qui cite le justificatif comme
    # pièce jointe et source de l'écriture : l'abonnement à `entry.posted` le
    # fait passer en « Rattaché ».
    module EntryScreenMethods
      alias Api = Document::Api

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
        return go(Ui.url("show", receipt.id)) unless receipt.to_process?
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
        render_entry(receipt, form, vat_rate || prefill.lines.first?.try(&.vat_rate) || "")
      end

      def post
        require!("ACCOUNTING", PERMISSION)
        receipt = Api.receipt(current.actor, receipt_id)
        form = PartiduoUi::EntryForm.read("purchase", form_values)
        if field("add_line") == "1"
          form.add_line
          return render_entry(receipt, form)
        end
        if index = field("remove_line").to_i?
          form.remove_line(index)
          return render_entry(receipt, form.renumber!)
        end
        input = entry_input(form)
        return render_entry(receipt, form, status: 422) unless input.is_a?(Partiduo::Api::Accounting::DocumentInput)
        result = Api.post_purchase(current.actor, receipt.id, input)
        if entry = result.value?
          flash["success"] = I18n.t("document_ui.flash.posted", receipt: entry.receipt.presence || entry.internal_code)
          return go(Ui.url("index"))
        end
        add_errors(form, result.errors)
        render_entry(receipt, form, status: 422)
      end

      private def render_entry(receipt : Api::ReceiptView, form : PartiduoUi::EntryForm, vat_rate : String = "",
                               status : Int32 = 200) : Marten::HTTP::Response
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
        if (input = entry_input(form)).is_a?(Partiduo::Api::Accounting::DocumentInput)
          result = Api.check_purchase(current.actor, receipt.id, input)
          if view = result.value?
            check.draft(view, document: true)
            amount = receipt.amount
            if amount && view.total_including_vat != amount
              gap = fmt.amount((view.total_including_vat - amount).abs)
            end
          else
            add_errors(form, result.errors)
          end
        end
        check.errors = messages(form)
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
