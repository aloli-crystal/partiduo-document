# SPDX-License-Identifier: AGPL-3.0-or-later

module Document
  # Contrat public de l'extension DOCUMENT, sur le modèle de `Partiduo::Api`
  # (DECISIONS C2) : acteur en premier argument, contrôle d'accès en première
  # ligne, objets de vue immuables, erreurs par champ. L'interface de
  # l'extension (`ui/bulma/`) et les autres extensions (`partiduo-einvoicing`
  # pour les factures reçues, `receive`) ne voient que ce module.
  #
  # Référence : `doc/api/document.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias FieldError = Partiduo::Api::FieldError
    alias Transaction = Partiduo::Api::Transaction
    alias Acc = Partiduo::Api::Accounting

    MODULE_CODE = Document::CODE
    READ        = "document.receipt.read"
    WRITE       = "document.receipt.write"

    # Permissions du socle exigées en plus pour les fichiers (D-DOC-004).
    ATTACHMENT_READ  = "core.attachment.read"
    ATTACHMENT_WRITE = "core.attachment.write"

    # `source` d'une écriture enregistrée depuis un justificatif :
    # `document:<id>` (lu par l'abonnement à `entry.posted`).
    SOURCE_PREFIX = "document:"

    # Taille maximale d'un fichier déposé (celle des pièces jointes du socle).
    MAX_BYTES = Partiduo::Core::Attachments::MAX_BYTES

    # Nombre maximal de justificatifs rendus par `receipts`.
    MAX_LIMIT = 500

    # --- Dépôt ---------------------------------------------------------------

    # Photographie ou fichier déposé (ADR-005 D8) : l'original est conservé
    # tel quel dans les pièces jointes du socle, le serveur produit une
    # vignette et une version réduite (conversion JPEG d'une photo HEIC).
    # Types admis : JPEG, PNG, HEIC, PDF, reconnus au contenu. Le
    # justificatif entre « À traiter ». Permissions `document.receipt.write`
    # et `core.attachment.write`.
    def self.capture(actor : Actor, input : CaptureInput) : Result(ReceiptView)
      authorize_write!(actor)
      errors = [] of FieldError
      source = input.source
      if source && !{"photo", "file"}.includes?(source)
        errors << FieldError.new("source", "document.errors.receipt.source.invalid", {"value" => source})
      end
      content_type = check_content(input.content, Receipts::CAPTURE_TYPES, "content", errors)
      details = Receipts.check_details(actor, input.details, errors)
      return Result(ReceiptView).failure(errors) unless errors.empty? && content_type

      source ||= content_type.starts_with?("image/") ? "photo" : "file"
      store(actor, source, input.filename, input.content, content_type, details)
    end

    # Contrôle d'un dépôt sans rien enregistrer (retour instantané).
    def self.check_capture(actor : Actor, input : CaptureInput) : Result(Nil)
      authorize_write!(actor)
      errors = [] of FieldError
      check_content(input.content, Receipts::CAPTURE_TYPES, "content", errors)
      Receipts.check_details(actor, input.details, errors)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    # Facture reçue par la plateforme agréée (API publique pour
    # `partiduo-einvoicing`, ADR-004 D9) : elle entre dans la même boîte, de
    # source `einvoice` et de nature `invoice`. Idempotente : une facture de
    # même `external_ref` déjà reçue est rendue telle quelle, sans doublon.
    # Permissions `document.receipt.write` et `core.attachment.write`
    # (`Actor.system` pour une synchronisation).
    def self.receive(actor : Actor, input : ReceiveInput) : Result(ReceiptView)
      authorize_write!(actor)
      external_ref = input.external_ref.strip
      if existing = (external_ref.empty? ? nil : Receipt.filter(external_ref: external_ref).first)
        return Result(ReceiptView).success(Receipts.view(existing))
      end

      errors = [] of FieldError
      if external_ref.empty?
        errors << FieldError.new("external_ref", "document.errors.receipt.external_ref.blank")
      elsif external_ref.size > 255
        errors << FieldError.new("external_ref", "document.errors.receipt.external_ref.too_long", {"max" => "255"})
      end
      content_type = check_content(input.content, Receipts::RECEIVE_TYPES, "content", errors)
      data_type = input.data.try { |data| check_content(data, Receipts::DATA_TYPES, "data", errors) }
      details = input.details.kind.empty? ? input.details.copy_with(kind: "invoice") : input.details
      checked = Receipts.check_details(actor, details, errors)
      return Result(ReceiptView).failure(errors) unless errors.empty? && content_type

      data = input.data
      store(actor, "einvoice", input.filename, input.content, content_type, checked, external_ref,
        data && data_type ? {input.data_filename || "facture.xml", data, data_type} : nil)
    end

    # --- Compléments et statuts ----------------------------------------------

    # Remplace les compléments d'un justificatif (quel que soit son statut).
    def self.update_details(actor : Actor, id : Int64, input : DetailsInput) : Result(ReceiptView)
      authorize_write!(actor, attachments: false)
      errors = [] of FieldError
      details = Receipts.check_details(actor, input, errors)
      return Result(ReceiptView).failure(errors) unless errors.empty?
      Transaction.run do
        receipt = Receipts.apply(Receipts.lock!(id), details)
        receipt.save!
        Result(ReceiptView).success(Receipts.view(receipt))
      end
    end

    def self.check_details(actor : Actor, input : DetailsInput) : Result(Nil)
      authorize_write!(actor, attachments: false)
      errors = [] of FieldError
      Receipts.check_details(actor, input, errors)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    # Écarte un justificatif « À traiter » (doublon, sans objet) ; il reste
    # consultable et peut être remis à traiter.
    def self.discard(actor : Actor, id : Int64) : Result(ReceiptView)
      authorize_write!(actor, attachments: false)
      Transaction.run do
        receipt = Receipts.lock!(id)
        next status_error(receipt, "not_to_process") unless receipt.status == "to_process"
        receipt.status = "discarded"
        receipt.discarded_at = Time.utc
        receipt.save!
        Result(ReceiptView).success(Receipts.view(receipt))
      end
    end

    # Remet « À traiter » un justificatif écarté, ou détache un justificatif
    # rattaché (l'écriture ou la facture n'est pas modifiée).
    def self.reopen(actor : Actor, id : Int64) : Result(ReceiptView)
      authorize_write!(actor, attachments: false)
      Transaction.run do
        receipt = Receipts.lock!(id)
        next status_error(receipt, "already_to_process") if receipt.status == "to_process"
        Result(ReceiptView).success(Receipts.view(Receipts.reopen!(receipt)))
      end
    end

    # Rattache un justificatif « À traiter » à une écriture existante de la
    # Comptabilité (lisible par l'acteur, non annulée).
    def self.link_entry(actor : Actor, id : Int64, entry_id : Int64) : Result(ReceiptView)
      authorize_write!(actor, attachments: false)
      Transaction.run do
        receipt = Receipts.lock!(id)
        next status_error(receipt, "not_to_process") unless receipt.status == "to_process"
        next module_error("entry_id", "ACCOUNTING") unless Partiduo::Modules.active?("ACCOUNTING")
        entry = begin
          Acc.entry(actor, entry_id)
        rescue Partiduo::Api::NotFound | Partiduo::Api::Forbidden
          next Result(ReceiptView).failure(FieldError.new("entry_id", "document.errors.receipt.entry_id.unknown",
            {"value" => entry_id.to_s}))
        end
        if entry.cancelled? || entry.reversal?
          next Result(ReceiptView).failure(FieldError.new("entry_id", "document.errors.receipt.entry_id.cancelled",
            {"value" => entry.internal_code}))
        end
        Result(ReceiptView).success(Receipts.view(Receipts.attach!(receipt, entry_id: entry.id, by: actor.user_id)))
      end
    end

    # Rattache un justificatif « À traiter » à un document émis de la
    # Facturation (facture, facture d'acompte, avoir).
    def self.link_invoice(actor : Actor, id : Int64, invoice_id : Int64) : Result(ReceiptView)
      authorize_write!(actor, attachments: false)
      Transaction.run do
        receipt = Receipts.lock!(id)
        next status_error(receipt, "not_to_process") unless receipt.status == "to_process"
        next module_error("invoice_id", "INVOICING") unless Partiduo::Modules.active?("INVOICING")
        document = begin
          Partiduo::Api::Invoicing.document(actor, invoice_id)
        rescue Partiduo::Api::NotFound | Partiduo::Api::Forbidden
          nil
        end
        if document.nil? || !Partiduo::Api::Invoicing::FISCAL_KINDS.includes?(document.kind) || document.number.nil?
          next Result(ReceiptView).failure(FieldError.new("invoice_id", "document.errors.receipt.invoice_id.unknown",
            {"value" => invoice_id.to_s}))
        end
        Result(ReceiptView).success(Receipts.view(Receipts.attach!(receipt, invoice_id: document.id, by: actor.user_id)))
      end
    end

    # --- Saisie de l'écriture --------------------------------------------------

    # Écriture d'achat préremplie depuis un justificatif (« Saisir
    # l'écriture ») : premier journal d'achats où l'acteur écrit, date du
    # justificatif (sinon du jour), fournisseur, libellé, une ligne hors taxe
    # déduite du montant TTC et du taux de TVA `vat_rate` (code) : `nil`,
    # le taux normal du dossier (catégorie `S` la plus élevée, hors
    # autoliquidation) ; `""`, aucun. Exige la Comptabilité active
    # (`ModuleDisabled` sinon).
    def self.purchase_prefill(actor : Actor, id : Int64, vat_rate : String? = nil) : PrefillView
      authorize_write!(actor, attachments: false)
      Guard.authorize!(actor, "accounting.entry.post", module_code: "ACCOUNTING")
      receipt = Receipts.view(Receipts.find!(id))
      ledger = Acc.ledgers(actor, Acc::LedgerKind::Purchase, enabled_only: true).find(&.access.write?)
      label = [receipt.supplier_name, receipt.reference.presence || receipt.note.lines.first?].compact
        .map(&.strip).reject(&.empty?).join(" · ")
      rate = if !actor.can?("vat.rate.read")
               nil
             elsif vat_rate.nil?
               Partiduo::Api::Vat.rates(actor).select { |item| item.category == "S" && !item.reverse_charge }.max_by?(&.rate)
             else
               vat_rate.presence.try { |code| Partiduo::Api::Vat.rate_by_code(actor, code) }
             end
      lines = [] of PrefillLineView
      total = receipt.amount
      if total && rate && !rate.fraction.zero?
        net = (total / (BigDecimal.new(1) + rate.fraction)).round(2, mode: :ties_away)
        lines << PrefillLineView.new(amount: net, vat_rate: rate.code, vat_amount: total - net, label: label)
      else
        lines << PrefillLineView.new(amount: total || BigDecimal.new(0), vat_rate: rate.try(&.code), vat_amount: nil,
          label: label)
      end
      PrefillView.new(
        ledger_id: ledger.try(&.id), date: receipt.date || Partiduo::Api::Core.today, third_party: receipt.supplier_code,
        label: label.empty? ? receipt.filename : label, lines: lines, amount_including_vat: total,
      )
    end

    # Contrôle de l'écriture d'achat avant enregistrement (même règle que
    # `post_purchase`, pour les totaux instantanés).
    def self.check_purchase(actor : Actor, id : Int64, input : Acc::DocumentInput) : Result(Acc::EntryDraftView)
      authorize_write!(actor, attachments: false)
      receipt = Receipts.find!(id)
      Acc.check_document(actor, with_receipt(input, receipt))
    end

    # Enregistre l'écriture d'achat d'un justificatif « À traiter » : la
    # pièce jointe de l'écriture est l'original du justificatif, sa source
    # `document:<id>`. L'abonnement à `entry.posted` fait passer le
    # justificatif en « Rattaché », dans la même transaction. Permissions de
    # la Comptabilité vérifiées par `post_purchase`.
    def self.post_purchase(actor : Actor, id : Int64, input : Acc::DocumentInput) : Result(Acc::EntryView)
      authorize_write!(actor, attachments: false)
      Transaction.run do
        receipt = Receipts.lock!(id)
        unless receipt.status == "to_process"
          next Result(Acc::EntryView).failure(FieldError.base("document.errors.receipt.status.not_to_process"))
        end
        Acc.post_purchase(actor, with_receipt(input, receipt))
      end
    end

    # --- Requêtes --------------------------------------------------------------

    def self.receipt(actor : Actor, id : Int64) : ReceiptView
      authorize_read!(actor)
      Receipts.view(Receipts.find!(id))
    end

    # Justificatifs selon `query`, du plus récent au plus ancien.
    def self.receipts(actor : Actor, query : ReceiptQuery = ReceiptQuery.new) : Array(ReceiptView)
      authorize_read!(actor)
      rows = filtered(query).order("-created_at", "-id")
      offset = Math.max(query.offset, 0)
      rows[offset...(offset + query.limit.clamp(1, MAX_LIMIT))].to_a.map { |row| Receipts.view(row) }
    end

    def self.count_receipts(actor : Actor, query : ReceiptQuery = ReceiptQuery.new) : Int64
      authorize_read!(actor)
      filtered(query).count.to_i64
    end

    # Nombre de justificatifs par statut.
    def self.counts(actor : Actor) : CountsView
      authorize_read!(actor)
      by_status = STATUSES.to_h { |status| {status, Receipt.filter(status: status).count.to_i64} }
      CountsView.new(by_status["to_process"], by_status["attached"], by_status["discarded"])
    end

    # Compteur du menu et du tableau de bord : justificatifs « À traiter ».
    # `nil` si l'extension est inactive ou l'acteur sans droit de lecture
    # (le compteur ne s'affiche pas).
    def self.pending_count(actor : Actor) : Int64?
      return unless Partiduo::Modules.active?(MODULE_CODE) && actor.can?(READ)
      Receipt.filter(status: "to_process").count.to_i64
    end

    # Fichier d'un justificatif : `original` (tel que déposé), `preview`
    # (version réduite), `thumbnail` (vignette), `data` (XML d'une facture
    # électronique). `NotFound` si la version n'existe pas. Permissions
    # `document.receipt.read` et `core.attachment.read`.
    def self.file(actor : Actor, id : Int64, variant : String = "original") : FileView
      authorize_read!(actor)
      Guard.authorize!(actor, ATTACHMENT_READ)
      receipt = Receipts.find!(id)
      attachment_id = case variant
                      when "original"  then receipt.original_attachment_id
                      when "preview"   then receipt.preview_attachment_id
                      when "thumbnail" then receipt.thumbnail_attachment_id
                      when "data"      then receipt.data_attachment_id
                      end
      raise Partiduo::Api::NotFound.new("receipt_file", id) if attachment_id.nil?
      attachment = Partiduo::Api::Core.attachment(actor, attachment_id.to_i64)
      FileView.new(attachment.filename, attachment.content_type,
        Partiduo::Api::Core.attachment_content(actor, attachment_id.to_i64))
    end

    # Doublons possibles d'un justificatif (ADR-004 D9, `warning_duplicate`
    # de NOALYSS) : même contenu, ou même fournisseur, même date et même
    # montant ; écritures d'achat déjà enregistrées pour la même fiche, à la
    # même date et au même montant (Comptabilité active et lisible).
    def self.duplicates(actor : Actor, id : Int64) : DuplicatesView
      authorize_read!(actor)
      receipt = Receipts.find!(id)
      same = Receipt.filter(sha256: receipt.sha256).exclude(id: id).exclude(status: "discarded").to_a
      amount, date = receipt.amount, receipt.document_date
      if amount && date && (receipt.supplier_card_id || !receipt.supplier_name.to_s.empty?)
        candidates = Receipt.filter(amount: amount, document_date: date).exclude(id: id).exclude(status: "discarded")
        candidates = if card = receipt.supplier_card_id
                       candidates.filter(supplier_card_id: card)
                     else
                       candidates.filter(supplier_name__iexact: receipt.supplier_name.to_s)
                     end
        same += candidates.to_a.reject { |row| same.any? { |other| other.id == row.id } }
      end
      entries = [] of CandidateView
      code = receipt.supplier_code.to_s
      if amount && date && !code.empty? && Partiduo::Modules.active?("ACCOUNTING") && actor.can?("accounting.entry.read")
        query = Acc::EntryQuery.new(ledger_kind: Acc::LedgerKind::Purchase, card: code, date_from: date, date_to: date,
          amount_min: amount, amount_max: amount, include_cancelled: false, limit: 10)
        entries = Acc.entries(actor, query).reject { |entry| entry.id == receipt.entry_id }.map { |entry| entry_candidate(entry) }
      end
      DuplicatesView.new(same.sort_by!(&.id!).map { |row| Receipts.view(row) }, entries)
    end

    # Écritures et documents de la Facturation auxquels rattacher un
    # justificatif : ceux dont le libellé, la pièce ou le numéro contient
    # `search` ; sans texte, les écritures d'achat de la fiche du fournisseur
    # (au montant du justificatif s'il est connu). Seuls les modules actifs
    # et lisibles par l'acteur sont consultés.
    def self.candidates(actor : Actor, id : Int64, search : String = "") : Array(CandidateView)
      authorize_write!(actor, attachments: false)
      receipt = Receipts.find!(id)
      text = search.strip
      found = [] of CandidateView
      if Partiduo::Modules.active?("ACCOUNTING") && actor.can?("accounting.entry.read")
        query = if !text.empty?
                  Acc::EntryQuery.new(text: text, include_cancelled: false, limit: 20)
                elsif !(code = receipt.supplier_code.to_s).empty?
                  Acc::EntryQuery.new(card: code, ledger_kind: Acc::LedgerKind::Purchase, include_cancelled: false,
                    amount_min: receipt.amount, amount_max: receipt.amount, limit: 20)
                end
        query.try { |criteria| found.concat(Acc.entries(actor, criteria).reject(&.reversal?).map { |entry| entry_candidate(entry) }) }
      end
      if !text.empty? && Partiduo::Modules.active?("INVOICING") && actor.can?("invoicing.invoice.read")
        documents = Partiduo::Api::Invoicing.documents(actor, Partiduo::Api::Invoicing::DocumentQuery.new(search: text, limit: 20))
        documents.each do |document|
          number = document.number
          next if number.nil? || !Partiduo::Api::Invoicing::FISCAL_KINDS.includes?(document.kind)
          found << CandidateView.new(kind: "invoice", id: document.id, reference: number, label: document.customer.name,
            date: document.issue_date || document.created_at, amount: document.totals.total_gross,
            third_party: document.customer.code)
        end
      end
      found
    end

    # --- Outils ----------------------------------------------------------------

    private def self.authorize_read!(actor : Actor) : Nil
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
    end

    private def self.authorize_write!(actor : Actor, attachments : Bool = true) : Nil
      Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
      Guard.authorize!(actor, ATTACHMENT_WRITE) if attachments
    end

    private def self.filtered(query : ReceiptQuery)
      rows = Receipt.all
      query.status.try { |status| rows = rows.filter(status: status) }
      query.source.try { |source| rows = rows.filter(source: source) }
      if text = query.search.try(&.strip).presence
        rows = rows.filter do
          q(supplier_name__icontains: text) | q(note__icontains: text) | q(reference__icontains: text) |
            q(filename__icontains: text) | q(supplier_code__icontains: text)
        end
      end
      rows
    end

    # Type reconnu d'un contenu parmi `allowed`, ou erreur sous `field`.
    private def self.check_content(bytes : Bytes, allowed : Array(String), field : String,
                                   errors : Array(FieldError)) : String?
      if bytes.empty?
        errors << FieldError.new(field, "document.errors.receipt.content.empty")
        return
      end
      if bytes.size > MAX_BYTES
        errors << FieldError.new(field, "document.errors.receipt.content.too_large",
          {"max" => (MAX_BYTES // (1024 * 1024)).to_s})
        return
      end
      type = Receipts.sniff(bytes)
      unless type && allowed.includes?(type)
        errors << FieldError.new(field, "document.errors.receipt.content.unsupported")
        return
      end
      type
    end

    # Enregistre l'original, les versions produites et la ligne.
    private def self.store(actor : Actor, source : String, filename : String, content : Bytes, content_type : String,
                           details : Receipts::Details, external_ref : String? = nil,
                           data : {String, Bytes, String}? = nil) : Result(ReceiptView)
      name = Receipts.filename(filename, content_type)
      # Rendu hors transaction : il peut prendre quelques secondes.
      renditions = Imaging.renditions(content, content_type)
      Transaction.run do
        original = Partiduo::Api::Core.store_attachment(actor,
          Partiduo::Api::Core::AttachmentInput.new(name, content_type, IO::Memory.new(content)))
        next Result(ReceiptView).failure(original.errors) if original.failure?
        stored = {} of String => Int64
        {"preview" => renditions.preview, "thumbnail" => renditions.thumbnail}.each do |variant, bytes|
          next if bytes.nil?
          result = Partiduo::Api::Core.store_attachment(actor,
            Partiduo::Api::Core::AttachmentInput.new(Receipts.rendition_name(name, variant), "image/jpeg", IO::Memory.new(bytes)))
          stored[variant] = result.value!.id if result.success?
        end
        if data
          result = Partiduo::Api::Core.store_attachment(actor,
            Partiduo::Api::Core::AttachmentInput.new(Receipts.filename(data[0], data[2]), data[2], IO::Memory.new(data[1])))
          next Result(ReceiptView).failure(result.errors.map { |error| FieldError.new("data", error.key, error.params) }) if result.failure?
          stored["data"] = result.value!.id
        end
        view = original.value!
        receipt = Receipt.new(
          source: source, status: "to_process", filename: view.filename, content_type: view.content_type,
          byte_size: view.byte_size, original_attachment_id: view.id, sha256: view.sha256,
          preview_attachment_id: stored["preview"]?, thumbnail_attachment_id: stored["thumbnail"]?,
          data_attachment_id: stored["data"]?, external_ref: external_ref, captured_by_id: actor.user_id,
        )
        Receipts.apply(receipt, details).save!
        Result(ReceiptView).success(Receipts.view(receipt))
      end
    end

    private def self.with_receipt(input : Acc::DocumentInput, receipt : Receipt) : Acc::DocumentInput
      input.copy_with(attachment_id: receipt.original_attachment_id.try(&.to_i64), source: "#{SOURCE_PREFIX}#{receipt.id}")
    end

    private def self.entry_candidate(entry : Acc::EntryView) : CandidateView
      third_party = entry.lines.find(&.card_code).try(&.card_code)
      CandidateView.new(kind: "entry", id: entry.id, reference: entry.receipt.presence || entry.internal_code,
        label: entry.label, date: entry.date, amount: entry.amount, third_party: third_party)
    end

    private def self.status_error(receipt : Receipt, code : String) : Result(ReceiptView)
      Result(ReceiptView).failure(FieldError.base("document.errors.receipt.status.#{code}",
        {"status" => receipt.status.to_s}))
    end

    private def self.module_error(field : String, code : String) : Result(ReceiptView)
      Result(ReceiptView).failure(FieldError.new(field, "document.errors.receipt.module_inactive", {"module" => code}))
    end
  end
end
