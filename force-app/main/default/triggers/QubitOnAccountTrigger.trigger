trigger QubitOnAccountTrigger on Account (after insert, after update) {
    if (QubitOnTriggerGuard.skip) return;
    Set<Id> ids = new Set<Id>();
    for (Account a : Trigger.new) {
        if (Trigger.isInsert) { ids.add(a.Id); continue; }
        Account o = Trigger.oldMap.get(a.Id);
        if (a.Name != o.Name || a.Phone != o.Phone || a.QubitOn_Tax_ID__c != o.QubitOn_Tax_ID__c
            || a.BillingStreet != o.BillingStreet || a.BillingCity != o.BillingCity || a.BillingState != o.BillingState
            || a.BillingPostalCode != o.BillingPostalCode || a.BillingCountry != o.BillingCountry) ids.add(a.Id);
    }
    QubitOnAccountScreening.enqueue(ids);
}
