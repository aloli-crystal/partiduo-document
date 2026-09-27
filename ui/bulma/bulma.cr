# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension DOCUMENT (ADR-005 D4, D8) : boîte
# « Justificatifs à traiter », prise de vue, saisie de l'écriture avec
# l'image à côté, rattachement. Montée par `partiduo-ui-bulma` sous
# `/ext/DOCUMENT/` (ADR-003 D3). La distribution la requiert après
# l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-document"
# require "partiduo-document/ui/bulma"
# ```
#
# puis ajoute `Document::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Document::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`) ; le contrôle d'accès
# est fait par l'interface, avant le handler, à partir du manifeste.
require "../../src/partiduo-document"

require "./receipt_form"
require "./handlers/**"

module Document
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/document/`), fichiers statiques (`assets/document/`) et
    # libellés d'écran (`locales/`, clés `document_ui.*`).
    class App < Marten::App
      label "document_ui"
    end

    INSTALLED_APPS = [Document::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/DOCUMENT/`, nommées `document:<nom>` :
    # `document:index` est la route que cite le menu du manifeste.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Document::Ui::IndexHandler, name: "index"
      path "/capture", Document::Ui::CaptureHandler, name: "capture"
      path "/<id:int>", Document::Ui::ShowHandler, name: "show"
      path "/<id:int>/file/<variant:str>", Document::Ui::FileHandler, name: "file"
      path "/<id:int>/details", Document::Ui::DetailsHandler, name: "details"
      path "/<id:int>/discard", Document::Ui::DiscardHandler, name: "discard"
      path "/<id:int>/reopen", Document::Ui::ReopenHandler, name: "reopen"
      path "/<id:int>/link", Document::Ui::LinkHandler, name: "link"
      path "/<id:int>/entry", Document::Ui::EntryHandler, name: "entry"
      path "/<id:int>/entry/check", Document::Ui::EntryCheckHandler, name: "entry_check"
    end

    # Routes qui modifient : `document.receipt.write` ; les autres (boîte,
    # consultation, fichiers) : `document.receipt.read`.
    WRITE_ROUTES = %w[capture details discard reopen link entry entry_check]
  end
end

PartiduoUi::Extensions.mount Document::CODE, Document::Ui::ROUTES, permission: Document::Api::READ,
  permissions: Document::Ui::WRITE_ROUTES.to_h { |route| {route, Document::Api::WRITE} }

# Compteur du menu et du tableau de bord (ADR-005 D8) : justificatifs à
# traiter, lus par le contrat de l'extension.
PartiduoUi::Extensions.counter("DOCUMENT_INBOX", route: "document:index", todo: "document_ui.todo") do |actor|
  Document::Api.pending_count(actor)
end
