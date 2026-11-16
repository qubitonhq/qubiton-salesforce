/** Email validation and PEP screening for Contacts, asynchronously. */
public with sharing class QubitOnContactScreening implements Queueable, Database.AllowsCallouts {
    @TestVisible private static final Integer PER_JOB = 20;
    private final List<Id> contactIds;
    public QubitOnContactScreening(List<Id> ids) { this.contactIds = ids; }

    public static void enqueue(Set<Id> ids) {
        if (ids.isEmpty() || Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) return;
        System.enqueueJob(new QubitOnContactScreening(new List<Id>(ids)));
    }

    public void execute(QueueableContext ctx) {
        List<Id> now = new List<Id>(), later = new List<Id>();
        for (Id i : contactIds) { if (now.size() < PER_JOB) now.add(i); else later.add(i); }
        List<Contact> cs = (List<Contact>) Database.query('SELECT Id, FirstName, LastName, Email, MailingCountry, Account.BillingCountry'
            + (QubitOnAccountScreening.HAS_CODES ? ', MailingCountryCode, Account.BillingCountryCode' : '') + ' FROM Contact WHERE Id IN :now');
        for (Contact c : cs) screen(c);
        QubitOnTriggerGuard.skip = true;
        update cs;
        QubitOnTriggerGuard.skip = false;
        if (!later.isEmpty() && !Test.isRunningTest()) System.enqueueJob(new QubitOnContactScreening(later));
    }

    @TestVisible
    private static void screen(Contact c) {
        List<String> errors = new List<String>();
        String country = QubitOnAccountScreening.pick(c, 'MailingCountryCode', 'MailingCountry');
        if (String.isBlank(country) && c.Account != null) country = QubitOnAccountScreening.pick(c.Account, 'BillingCountryCode', 'BillingCountry');
        if (String.isBlank(country)) country = 'US';
        if (String.isNotBlank(c.Email)) {
            try {
                Map<String, Object> r = QubitOnService.validateEmail(c.Email);
                Boolean pass = false;
                if (r.get('validationResults') instanceof List<Object>)
                    for (Object o : (List<Object>) r.get('validationResults')) if (((Map<String, Object>) o).get('validationPass') == true) pass = true;
                c.QubitOn_Email_Status__c = pass ? 'Valid' : 'Not verified';
            } catch (Exception e) { errors.add('Email: ' + e.getMessage()); }
        }
        String fullName = String.join(new List<String>{ c.FirstName == null ? '' : c.FirstName, c.LastName }, ' ').trim();
        try {
            Set<String> names = new Set<String>();
            for (Object o : QubitOnService.screenPep(fullName, country)) {
                Map<String, Object> m = (Map<String, Object>) o;
                if (m.get('persons') instanceof List<Object>)
                    for (Object p : (List<Object>) m.get('persons')) names.add(String.valueOf(((Map<String, Object>) p).get('name')));
            }
            c.QubitOn_PEP_Status__c = names.isEmpty() ? 'Clear' : 'Potential PEP';
            c.QubitOn_PEP_Detail__c = names.isEmpty() ? null : String.join(new List<String>(names), '\n').left(32000);
        } catch (Exception e) { errors.add('PEP: ' + e.getMessage()); }
        c.QubitOn_Error__c = errors.isEmpty() ? null : String.join(errors, '\n').left(255);
        c.QubitOn_Last_Checked__c = System.now();
    }
}
