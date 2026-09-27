# SPDX-License-Identifier: AGPL-3.0-or-later

module Document
  module Ui
    # Présentation d'un justificatif pour les gabarits (objets à attributs,
    # D-UI-010 de l'interface) : textes déjà mis en forme dans la langue de
    # l'utilisateur, adresses des actions.
    class ReceiptCard
      include Marten::Template::Object::Auto

      getter id : Int64
      getter title : String
      getter meta : String
      getter amount : String?
      getter source : String
      getter source_label : String
      getter status : String
      getter status_label : String
      getter show_url : String
      getter thumbnail_url : String?
      getter preview_url : String?
      getter original_url : String
      getter data_url : String?
      getter pdf : Bool
      getter to_process : Bool
      getter attached : Bool
      getter discarded : Bool
      getter linked_label : String?
      getter linked_url : String?
      getter entry_url : String?
      getter link_url : String?
      getter alt : String

      def initialize(receipt : Document::Api::ReceiptView, fmt : PartiduoUi::Format, @entry_url : String? = nil,
                     @link_url : String? = nil, @linked_label : String? = nil, @linked_url : String? = nil)
        @id = receipt.id
        kind = receipt.kind.presence.try { |code| I18n.t("document.kinds.#{code}") }
        @title = receipt.supplier_name.presence || kind || receipt.filename
        parts = [] of String
        parts << (kind || receipt.filename) if receipt.supplier_name.presence
        parts << receipt.reference if receipt.reference.presence
        parts << fmt.date(receipt.date || receipt.created_at)
        parts << receipt.note if receipt.note.presence
        @meta = parts.join(" · ")
        @amount = receipt.amount.try do |value|
          text = fmt.amount(value)
          receipt.currency_code.empty? ? text : "#{text} #{receipt.currency_code}"
        end
        @source = receipt.source
        @source_label = I18n.t("document.sources.#{receipt.source}")
        @status = receipt.status
        @status_label = I18n.t("document.statuses.#{receipt.status}")
        @show_url = Ui.url("show", receipt.id)
        @thumbnail_url = receipt.thumbnail_attachment_id ? Ui.url("file", receipt.id, "thumbnail") : nil
        @preview_url = receipt.preview_attachment_id ? Ui.url("file", receipt.id, "preview") : nil
        @original_url = Ui.url("file", receipt.id, "original")
        @data_url = receipt.data_attachment_id ? Ui.url("file", receipt.id, "data") : nil
        @pdf = receipt.pdf?
        @to_process = receipt.to_process?
        @attached = receipt.attached?
        @discarded = receipt.discarded?
        @alt = I18n.t("document_ui.card.alt", title: @title)
      end
    end

    # Onglet de la boîte (statut) avec son nombre.
    class StatusTab
      include Marten::Template::Object::Auto

      getter label : String
      getter url : String
      getter current : Bool
      getter count : Int64

      def initialize(@label, @url, @current, @count)
      end
    end

    # Option d'une liste de choix (`<option>` ou `<datalist>`).
    class Choice
      include Marten::Template::Object::Auto

      getter value : String
      getter label : String
      getter selected : Bool

      def initialize(@value, @label, @selected = false)
      end
    end

    # Compléments d'un justificatif, relus d'un formulaire ou d'une vue.
    # Le fournisseur se saisit dans un seul champ : texte libre, ou
    # « CODE · Nom » choisi dans la liste des fiches fournisseurs (maquette).
    class DetailsValues
      include Marten::Template::Object::Auto

      getter supplier : String
      getter amount : String
      getter date : String
      getter kind : String
      getter reference : String
      getter note : String

      def initialize(@supplier = "", @amount = "", @date = "", @kind = "", @reference = "", @note = "")
      end

      def self.from(receipt : Document::Api::ReceiptView, fmt : PartiduoUi::Format) : self
        supplier = receipt.supplier_code.presence.try { |code| "#{code} · #{receipt.supplier_name}" } || receipt.supplier_name
        new(supplier, receipt.amount.try { |value| fmt.input_number(value, 4) } || "",
          receipt.date.try(&.to_s("%Y-%m-%d")) || "", receipt.kind, receipt.reference, receipt.note)
      end

      # Champs du formulaire (`supplier`, `amount`, `date`, `kind`,
      # `reference`, `note`).
      def self.read(handler : PartiduoUi::Handler) : self
        new(handler.field("supplier"), handler.field("amount"), handler.field("date"), handler.field("kind"),
          handler.field("reference"), handler.field("note"))
      end

      # Entrée du contrat ; les montants et dates illisibles sont rangés
      # dans `errors` (message traduit, par champ).
      def input(fmt : PartiduoUi::Format, errors : Hash(String, Array(String))) : Document::Api::DetailsInput
        code, name = split_supplier
        amount_value = nil
        unless amount.empty?
          amount_value = fmt.parse_decimal(amount)
          (errors["amount"] ||= [] of String) << I18n.t("document_ui.errors.amount") if amount_value.nil?
        end
        date_value = nil
        unless date.empty?
          date_value = fmt.parse_date(date)
          (errors["date"] ||= [] of String) << I18n.t("document_ui.errors.date") if date_value.nil?
        end
        Document::Api::DetailsInput.new(supplier_name: name, supplier_code: code, amount: amount_value,
          date: date_value, kind: kind, note: note, reference: reference)
      end

      private def split_supplier : {String?, String}
        code, separator, name = supplier.partition(" · ")
        separator.empty? ? {nil, supplier} : {code.strip.presence, name.strip}
      end
    end

    # Adresse d'une route de l'extension (`document:<nom>`).
    def self.url(name : String, id : Int64? = nil, variant : String? = nil) : String
      if variant && id
        Marten.routes.reverse("document:#{name}", id: id, variant: variant)
      elsif id
        Marten.routes.reverse("document:#{name}", id: id)
      else
        Marten.routes.reverse("document:#{name}")
      end
    end

    # Adresse d'un écran de l'interface, `nil` s'il n'existe pas.
    def self.route(name : String, **params) : String?
      Marten.routes.reverse(name, **params)
    rescue Marten::Routing::Errors::NoReverseMatch
      nil
    end
  end
end
