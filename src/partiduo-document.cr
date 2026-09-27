# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-document` : le métier de l'extension
# DOCUMENT (manifeste, modèle, abonnements, contrat `Document::Api`), sans
# interface. L'interface Bulma est dans `ui/bulma/`, requise à part par la
# distribution : `require "partiduo-document/ui/bulma"`.
#
# La distribution ajoute ensuite `Document::INSTALLED_APPS` à ses
# applications Marten, et `require "partiduo-document/cli"` à sa ligne de
# commande (migrations).
require "partiduo"

require "./document/app"
