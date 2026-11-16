/** Re-polls beneficial ownership lookups that the registry was still building. */
public with sharing class QubitOnOwnershipRecheck implements Queueable, Database.AllowsCallouts {
    @TestVisible private static final Integer MAX_ATTEMPTS = 3;
    private final List<Id> ids; private final Integer attempt;
    public QubitOnOwnershipRecheck(List<Id> ids, Integer attempt) { this.ids = ids; this.attempt = attempt; }

    public static void schedule(Set<Id> ids, Integer attempt) {
        if (ids.isEmpty() || attempt > MAX_ATTEMPTS || Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) return;
        AsyncOptions opts = new AsyncOptions();
        opts.MinimumQueueableDelayInMinutes = 1;
        System.enqueueJob(new QubitOnOwnershipRecheck(new List<Id>(ids), attempt), opts);
    }

    public void execute(QueueableContext ctx) {
        List<Account> accts = (List<Account>) Database.query('SELECT Id, Name, BillingCountry'
            + (QubitOnAccountScreening.HAS_CODES ? ', BillingCountryCode' : '') + ' FROM Account WHERE Id IN :ids LIMIT 50');
        Set<Id> still = new Set<Id>();
        for (Account a : accts) {
            String c = QubitOnAccountScreening.normalizeCountry(QubitOnAccountScreening.pick(a, 'BillingCountryCode', 'BillingCountry'));
            try {
                if (QubitOnAccountScreening.applyOwnershipPublic(a, QubitOnService.beneficialOwnership(a.Name, c))) still.add(a.Id);
            } catch (Exception e) { a.QubitOn_UBO_Status__c = 'Error'; a.QubitOn_Error__c = ('Ownership: ' + e.getMessage()).left(255); }
        }
        if (attempt >= MAX_ATTEMPTS || Test.isRunningTest())
            for (Account a : accts) if (still.contains(a.Id)) a.QubitOn_UBO_Status__c = 'Still building after ' + attempt + ' attempt(s)';
        QubitOnTriggerGuard.skip = true; update accts; QubitOnTriggerGuard.skip = false;
        if (!Test.isRunningTest()) schedule(still, attempt + 1);
    }
}
