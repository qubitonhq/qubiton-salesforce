trigger QubitOnContactTrigger on Contact (after insert, after update) {
    if (QubitOnTriggerGuard.skip) return;
    Set<Id> ids = new Set<Id>();
    for (Contact c : Trigger.new) {
        if (Trigger.isInsert) { ids.add(c.Id); continue; }
        Contact o = Trigger.oldMap.get(c.Id);
        if (c.FirstName != o.FirstName || c.LastName != o.LastName || c.Email != o.Email || c.MailingCountry != o.MailingCountry) ids.add(c.Id);
    }
    QubitOnContactScreening.enqueue(ids);
}
