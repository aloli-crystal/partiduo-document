# SPDX-License-Identifier: AGPL-3.0-or-later

module Document
  module Ui
    # Base des écrans de l'extension : coquille de l'application, fil
    # d'Ariane « Saisie › Justificatifs », présentation des justificatifs.
    # L'accès a déjà été contrôlé par `PartiduoUi::ExtensionHandler` à partir
    # du manifeste ; `Document::Api` le vérifie encore.
    abstract class Handler < PartiduoUi::ScreenHandler
      alias Api = Document::Api
      alias Acc = Partiduo::Api::Accounting

      def receipt_id : Int64
        id_param
      end

      def crumbs(current_label : String? = nil) : Array(PartiduoUi::Screen::Crumb)
        list = [crumb("core.menu.entry"), PartiduoUi::Screen::Crumb.new(I18n.t("document.menu.document_inbox"),
          current_label ? Ui.url("index") : nil)]
        list << PartiduoUi::Screen::Crumb.new(current_label) if current_label
        list
      end

      def can_write? : Bool
        can?(Api::WRITE)
      end

      # « Saisir l'écriture » : Comptabilité active et droit d'enregistrer.
      def can_post? : Bool
        can_write? && module_active?("ACCOUNTING") && can?("accounting.entry.post")
      end

      # « Rattacher » : Comptabilité ou Facturation lisible.
      def can_link? : Bool
        can_write? && ((module_active?("ACCOUNTING") && can?("accounting.entry.read")) ||
          (module_active?("INVOICING") && can?("invoicing.invoice.read")))
      end

      # Justificatif traité ici : « À traiter » et pas une facture reçue par
      # la plateforme, qui se traite dans l'écran de l'extension de
      # facturation électronique (D-DOC-012).
      def processable?(receipt : Api::ReceiptView) : Bool
        receipt.to_process? && receipt.source != "einvoice"
      end

      def card(receipt : Api::ReceiptView) : ReceiptCard
        label, url = linked(receipt)
        ReceiptCard.new(receipt, fmt,
          entry_url: processable?(receipt) && can_post? ? Ui.url("entry", receipt.id) : nil,
          link_url: processable?(receipt) && can_link? ? Ui.url("link", receipt.id) : nil,
          linked_label: label, linked_url: url)
      end

      # Écriture ou facture à laquelle le justificatif est rattaché : libellé
      # (« Rattaché à ACH-0139 ») et adresse de sa consultation.
      def linked(receipt : Api::ReceiptView) : {String?, String?}
        if entry_id = receipt.entry_id
          reference = begin
            entry = Acc.entry(current.actor, entry_id)
            entry.receipt.presence || entry.internal_code
          rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
            "##{entry_id}"
          end
          {I18n.t("document_ui.card.linked_entry", reference: reference), Ui.route("accounting:entry", id: entry_id)}
        elsif invoice_id = receipt.invoice_id
          reference = begin
            Partiduo::Api::Invoicing.document(current.actor, invoice_id).number || "##{invoice_id}"
          rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
            "##{invoice_id}"
          end
          {I18n.t("document_ui.card.linked_invoice", reference: reference), Ui.route("invoicing:document", id: invoice_id)}
        else
          {nil, nil}
        end
      end

      # Fiches fournisseurs proposées dans le champ « Fournisseur »
      # (`CODE · Nom`), si l'acteur peut lire les fiches.
      def supplier_choices : Array(Choice)?
        return unless can?("cards.card.read")
        cards = Partiduo::Api::Cards.cards(current.actor, Partiduo::Api::Cards::CardQuery.new(kind: "supplier", limit: 500))
        listed(cards.map { |item| Choice.new("#{item.code} · #{item.name}", item.name) })
      end

      def kind_choices(selected : String) : Array(Choice)
        [Choice.new("", I18n.t("document_ui.form.kind_none"), selected.empty?)] +
          Api::KINDS.map { |kind| Choice.new(kind, I18n.t("document.kinds.#{kind}"), kind == selected) }
      end

      # Erreurs du contrat traduites, rangées par champ du formulaire
      # (`content` → `file`, `supplier_code`/`supplier_name` → `supplier`).
      def errors_by_field(errors : Array(Partiduo::Api::FieldError),
                          into = {} of String => Array(String)) : Hash(String, Array(String))
        errors.each do |error|
          field = case error.field
                  when "content", "source"              then "file"
                  when "supplier_code", "supplier_name" then "supplier"
                  when "currency_code"                  then "amount"
                  when "amount", "date", "kind", "note", "reference"
                    error.field
                  else
                    "base"
                  end
          (into[field] ||= [] of String) << fmt.message(error)
        end
        into
      end
    end

    # Boîte « Justificatifs à traiter » (`/ext/DOCUMENT/`, maquette
    # « Justificatifs ») : onglets par statut, prise de vue et dépôt,
    # cartes des justificatifs.
    class IndexHandler < Handler
      def get
        show(DetailsValues.new, {} of String => Array(String))
      end

      def show(values : DetailsValues, errors : Hash(String, Array(String)), status : Int32 = 200) : Marten::HTTP::Response
        actor = current.actor
        current_status = Api::STATUSES.includes?(query("status")) ? query("status") : "to_process"
        counts = Api.counts(actor)
        by_status = {"to_process" => counts.to_process, "attached" => counts.attached, "discarded" => counts.discarded}
        tabs = Api::STATUSES.map do |code|
          StatusTab.new(I18n.t("document_ui.tabs.#{code}"), "#{Ui.url("index")}?status=#{code}",
            code == current_status, by_status[code])
        end
        search = query("q")
        receipts = Api.receipts(actor, Api::ReceiptQuery.new(status: current_status, search: search.presence))
        page("document/index.html", {
          "title"     => I18n.t("document_ui.index.title"),
          "crumbs"    => crumbs,
          "tabs"      => tabs,
          "status"    => current_status,
          "search"    => search,
          "cards"     => listed(receipts.map { |receipt| card(receipt) }),
          "can_write" => can_write? && can?(Api::ATTACHMENT_WRITE),
          "values"    => values,
          "errors"    => errors,
          "kinds"     => kind_choices(values.kind),
          "suppliers" => supplier_choices,
          "today"     => Partiduo::Api::Core.today.to_s("%Y-%m-%d"),
          "max_mb"    => (Api::MAX_BYTES // (1024 * 1024)).to_s,
        }, status: status)
      end
    end

    # Dépôt d'une photo ou d'un fichier (formulaire `multipart/form-data`
    # de la boîte) : le justificatif entre « À traiter ».
    class CaptureHandler < IndexHandler
      def get
        go(Ui.url("index"))
      end

      def post
        values = DetailsValues.read(self)
        errors = {} of String => Array(String)
        upload = request.data.fetch("file", nil).as?(Marten::HTTP::UploadedFile)
        content = upload.try { |file| read(file) }
        details = values.input(fmt, errors)
        if content.nil? || content.empty?
          (errors["file"] ||= [] of String) << I18n.t("document_ui.errors.file_missing")
        end
        return show(values, errors, 422) unless errors.empty? && content

        result = Api.capture(current.actor, Api::CaptureInput.new(filename: upload.try(&.filename) || "", content: content,
          details: details))
        return show(values, errors_by_field(result.errors), 422) if result.failure?

        flash["success"] = I18n.t("document_ui.flash.captured")
        go(Ui.url("index"))
      ensure
        upload.try { |file| file.io.delete rescue nil }
      end

      private def read(file : Marten::HTTP::UploadedFile) : Bytes
        io = file.io
        io.rewind
        io.getb_to_end
      end
    end

    # Consultation d'un justificatif : l'image à côté des compléments,
    # doublons possibles, actions selon le statut.
    class ShowHandler < Handler
      def get
        receipt = Api.receipt(current.actor, receipt_id)
        show(receipt, DetailsValues.from(receipt, fmt), {} of String => Array(String))
      end

      def show(receipt : Api::ReceiptView, values : DetailsValues, errors : Hash(String, Array(String)),
               status : Int32 = 200) : Marten::HTTP::Response
        duplicates = Api.duplicates(current.actor, receipt.id)
        receipt_card = card(receipt)
        page("document/show.html", {
          "title"      => receipt_card.title,
          "crumbs"     => crumbs(receipt_card.title),
          "receipt"    => receipt_card,
          "source"     => receipt.source,
          "values"     => values,
          "errors"     => errors,
          "kinds"      => kind_choices(values.kind),
          "suppliers"  => supplier_choices,
          "can_write"  => can_write?,
          "can_files"  => can?(Api::ATTACHMENT_READ),
          "duplicates" => listed(duplicates.receipts.map { |other| card(other) }),
          "entries"    => listed(duplicates.entries.map { |entry| candidate(entry) }),
          "captured"   => fmt.datetime(receipt.created_at),
          "size"       => I18n.t("document_ui.show.size", size: fmt.number(BigDecimal.new(receipt.byte_size) / 1024, 0)),
        }, status: status)
      end

      def candidate(view : Api::CandidateView) : Hash(String, String?)
        {
          "reference" => view.reference, "label" => view.label, "date" => fmt.date(view.date),
          "amount" => fmt.amount(view.amount),
          "url" => view.kind == "entry" ? Ui.route("accounting:entry", id: view.id) : Ui.route("invoicing:document", id: view.id),
        }
      end
    end

    # Fichier d'un justificatif : original, version réduite, vignette,
    # données structurées (XML d'une facture électronique).
    class FileHandler < Handler
      def get
        variant = params["variant"].to_s
        raise Partiduo::Api::NotFound.new("receipt_file", receipt_id) unless Api::VARIANTS.includes?(variant)
        file = Api.file(current.actor, receipt_id, variant)
        response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
        disposition = variant == "data" || query("download") == "1" ? "attachment" : "inline"
        response["Content-Disposition"] = %(#{disposition}; filename="#{file.filename.gsub(/["\\\r\n]/, "_")}")
        response["X-Content-Type-Options"] = "nosniff"
        response["Cache-Control"] = "private, max-age=3600"
        response
      end
    end

    # Compléments modifiés depuis la consultation.
    class DetailsHandler < ShowHandler
      def get
        go(Ui.url("show", receipt_id))
      end

      def post
        values = DetailsValues.read(self)
        errors = {} of String => Array(String)
        details = values.input(fmt, errors)
        if errors.empty?
          result = Api.update_details(current.actor, receipt_id, details)
          if result.success?
            flash["success"] = I18n.t("document_ui.flash.saved")
            return go(Ui.url("show", receipt_id))
          end
          errors_by_field(result.errors, errors)
        end
        show(Api.receipt(current.actor, receipt_id), values, errors, 422)
      end
    end

    # Changement de statut : écarter, remettre à traiter.
    abstract class StatusHandler < Handler
      abstract def change(id : Int64) : Partiduo::Api::Result(Api::ReceiptView)
      abstract def done_key : String

      def get
        go(Ui.url("show", receipt_id))
      end

      def post
        result = change(receipt_id)
        if result.success?
          flash["success"] = I18n.t(done_key)
        else
          flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
        end
        go(Ui.url("show", receipt_id))
      end
    end

    class DiscardHandler < StatusHandler
      def change(id : Int64) : Partiduo::Api::Result(Api::ReceiptView)
        Api.discard(current.actor, id)
      end

      def done_key : String
        "document_ui.flash.discarded"
      end
    end

    class ReopenHandler < StatusHandler
      def change(id : Int64) : Partiduo::Api::Result(Api::ReceiptView)
        Api.reopen(current.actor, id)
      end

      def done_key : String
        "document_ui.flash.reopened"
      end
    end

    # « Rattacher » : recherche d'une écriture ou d'une facture existante,
    # puis rattachement.
    class LinkHandler < Handler
      def get
        receipt = Api.receipt(current.actor, receipt_id)
        return go(Ui.url("show", receipt.id)) if receipt.source == "einvoice"
        show(receipt, nil)
      end

      def post
        target = field("target").to_i64?
        result = case field("kind")
                 when "entry"   then target ? Api.link_entry(current.actor, receipt_id, target) : nil
                 when "invoice" then target ? Api.link_invoice(current.actor, receipt_id, target) : nil
                 end
        if result.nil?
          return show(Api.receipt(current.actor, receipt_id), [I18n.t("document_ui.errors.target_missing")], 422)
        end
        if result.success?
          flash["success"] = I18n.t("document_ui.flash.linked")
          return go(Ui.url("index"))
        end
        show(Api.receipt(current.actor, receipt_id), result.errors.map { |error| fmt.message(error) }, 422)
      end

      private def show(receipt : Api::ReceiptView, errors : Array(String)?, status : Int32 = 200) : Marten::HTTP::Response
        search = query("q").presence || field("q")
        candidates = Api.candidates(current.actor, receipt.id, search).map do |view|
          {
            "kind" => view.kind, "id" => view.id.to_s, "reference" => view.reference, "label" => view.label,
            "date" => fmt.date(view.date), "amount" => fmt.amount(view.amount), "third_party" => view.third_party || "",
            "kind_label" => I18n.t("document_ui.link.kinds.#{view.kind}"),
          }
        end
        receipt_card = card(receipt)
        page("document/link.html", {
          "title"      => I18n.t("document_ui.link.title"),
          "crumbs"     => crumbs(receipt_card.title),
          "receipt"    => receipt_card,
          "search"     => search,
          "candidates" => listed(candidates),
          "errors"     => errors,
          "to_process" => receipt.to_process?,
        }, status: status)
      end
    end
  end
end
