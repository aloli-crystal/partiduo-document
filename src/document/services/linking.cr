# SPDX-License-Identifier: AGPL-3.0-or-later

module Document
  # Abonnements aux événements de la Comptabilité (interne ; appelés par le
  # manifeste, dans la transaction de l'écriture, ADR-003 D7).
  module Linking
    # Préfixe de la `source` d'une écriture enregistrée depuis un justificatif.
    SOURCE_PATTERN = /\Adocument:(\d+)\z/

    # `entry.posted` : une écriture dont la source est `document:<id>` fait
    # passer ce justificatif en « Rattaché » (ADR-005 D8). Une extourne
    # (`reversal_of`) n'est pas un rattachement. Justificatif déjà rattaché
    # ou disparu : rien à faire.
    def self.entry_posted(event : Partiduo::Events::Event) : Nil
      return if event["reversal_of"]?
      match = event["source"]?.try { |source| SOURCE_PATTERN.match(source) }
      return if match.nil?
      entry_id = event["entry_id"].to_i64? ||
                 raise ArgumentError.new("entry.posted : entry_id illisible « #{event["entry_id"]} »")
      receipt = Receipt.all.lock.filter(id: match[1].to_i64).first
      return if receipt.nil? || receipt.status == "attached"
      Receipts.attach!(receipt, entry_id: entry_id, by: event.actor_user_id)
      nil
    end

    # `entry.cancelled` : les justificatifs rattachés à l'écriture extournée
    # reviennent « À traiter ».
    def self.entry_cancelled(event : Partiduo::Events::Event) : Nil
      entry_id = event["entry_id"].to_i64? ||
                 raise ArgumentError.new("entry.cancelled : entry_id illisible « #{event["entry_id"]} »")
      Receipt.all.lock.filter(entry_id: entry_id, status: "attached").to_a.each { |receipt| Receipts.reopen!(receipt) }
      nil
    end
  end
end
