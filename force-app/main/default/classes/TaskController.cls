/**
 * @description       :
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             :
 * @last modified on  : 03-27-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
public with sharing class TaskController {

    @AuraEnabled(cacheable=true)
    public static List<To_Do_Task__c> getPendingTasks() {
        return [
            SELECT Id, Name, Completed__c, Priority__c, Category__c, Notes__c, Sort_Order__c, Recurrence__c
            FROM To_Do_Task__c
            WHERE Completed__c = false
            AND OwnerId = :UserInfo.getUserId()
            WITH SECURITY_ENFORCED
            ORDER BY Sort_Order__c ASC NULLS LAST, CreatedDate DESC
            LIMIT 200
        ];
    }

    // cacheBuster is never used in the query — its only job is to give the client's
    // @wire cache a fresh key on every call. Without it, switching between filter
    // values (e.g. All -> Archived) can silently replay a stale cached response for
    // a filter value the client already queried earlier in the session, even after
    // a mutation (like Clear Completed) has changed what that filter should return —
    // because refreshApex only busts the cache entry for the currently active filter.
    @AuraEnabled(cacheable=true)
    public static List<To_Do_Task__c> getCompletedTasks(String filterType, Integer cacheBuster) {

        // The Archived view shows tasks "Clear Completed" hid from the normal list —
        // it's the only view that includes Archived__c = true records.
        if (filterType == 'ARCHIVED') {
            return [
                SELECT Id, Name, Completed_Date__c, Priority__c, Category__c, Notes__c, Recurrence__c
                FROM To_Do_Task__c
                WHERE Status__c = 'Completed'
                AND Archived__c = true
                AND OwnerId = :UserInfo.getUserId()
                WITH SECURITY_ENFORCED
                ORDER BY Completed_Date__c DESC NULLS LAST
                LIMIT 200
            ];
        }

        Date startDate;

        if (filterType == 'WEEK') {
            startDate = Date.today().toStartOfWeek();
        } else if (filterType == 'MONTH') {
            startDate = Date.today().toStartOfMonth();
        }

        if (startDate != null) {
            return [
                SELECT Id, Name, Completed_Date__c, Priority__c, Category__c, Notes__c, Recurrence__c
                FROM To_Do_Task__c
                WHERE Status__c = 'Completed'
                AND Archived__c = false
                AND OwnerId = :UserInfo.getUserId()
                AND Completed_Date__c >= :startDate
                WITH SECURITY_ENFORCED
                ORDER BY Completed_Date__c DESC NULLS LAST
                LIMIT 200
            ];
        } else {
            return [
                SELECT Id, Name, Completed_Date__c, Priority__c, Category__c, Notes__c, Recurrence__c
                FROM To_Do_Task__c
                WHERE Status__c = 'Completed'
                AND Archived__c = false
                AND OwnerId = :UserInfo.getUserId()
                WITH SECURITY_ENFORCED
                ORDER BY Completed_Date__c DESC NULLS LAST
                LIMIT 200
            ];
        }
    }

    // Sets the fields that mark a task as completed, including scheduling the next
    // occurrence if the task recurs. Shared by toggleTaskStatus and markAllTasksComplete.
    private static void applyCompletion(To_Do_Task__c t) {
        t.Completed__c = true;
        t.Status__c = 'Completed';
        t.Completed_Date__c = Date.today();

        if (t.Recurrence__c == 'Daily') {
            t.Next_Occurrence_Date__c = Date.today().addDays(1);
        } else if (t.Recurrence__c == 'Weekly') {
            t.Next_Occurrence_Date__c = Date.today().addDays(7);
        } else if (t.Recurrence__c == 'Monthly') {
            t.Next_Occurrence_Date__c = Date.today().addMonths(1);
        }
    }

    @AuraEnabled
    public static void toggleTaskStatus(Id taskId) {
        try {
            // Scoping the query to the running user's own records prevents one user
            // from toggling a task that belongs to someone else (IDOR protection).
            To_Do_Task__c t = [
                SELECT Id, Completed__c, Recurrence__c
                FROM To_Do_Task__c
                WHERE Id = :taskId
                AND OwnerId = :UserInfo.getUserId()
                WITH SECURITY_ENFORCED
            ];

            Boolean willBeCompleted = !t.Completed__c;

            if (willBeCompleted) {
                applyCompletion(t);
            } else {
                t.Completed__c = false;
                t.Completed_Date__c = null;
                t.Status__c = 'Pending';
                t.Next_Occurrence_Date__c = null;
            }

            SObjectAccessDecision decision = Security.stripInaccessible(
                AccessType.UPDATABLE, new List<To_Do_Task__c>{ t }
            );
            update decision.getRecords();
        } catch (QueryException e) {
            // Same message whether the task doesn't exist or belongs to another user —
            // avoids leaking which case it was.
            throw new AuraHandledException('Task not found');
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    @AuraEnabled
    public static void createTask(String taskName) {
        if (String.isBlank(taskName)) {
            throw new AuraHandledException('Task name cannot be empty');
        }
        try {
            To_Do_Task__c newTask = new To_Do_Task__c(
                Name = taskName,
                Completed__c = false,
                Status__c = 'Pending',
                Priority__c = 'Medium',
                Recurrence__c = 'None'
            );

            SObjectAccessDecision decision = Security.stripInaccessible(
                AccessType.CREATABLE, new List<To_Do_Task__c>{ newTask }
            );
            insert decision.getRecords();
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    @AuraEnabled
    public static void deleteTask(Id taskId) {
        if (!Schema.sObjectType.To_Do_Task__c.isDeletable()) {
            throw new AuraHandledException('Insufficient permissions to delete this task');
        }
        try {
            // Scoping the query to the running user's own records prevents one user
            // from deleting a task that belongs to someone else (IDOR protection).
            To_Do_Task__c t = [
                SELECT Id
                FROM To_Do_Task__c
                WHERE Id = :taskId
                AND OwnerId = :UserInfo.getUserId()
                WITH SECURITY_ENFORCED
            ];
            delete t;
        } catch (QueryException e) {
            throw new AuraHandledException('Task not found');
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    @AuraEnabled
    public static void updateTask(Id taskId, String newName, String priority, String category, String notes, String recurrence) {
        if (String.isBlank(newName)) {
            throw new AuraHandledException('Task name cannot be empty');
        }
        try {
            // Scoping the query to the running user's own records prevents one user
            // from editing a task that belongs to someone else (IDOR protection).
            To_Do_Task__c t = [
                SELECT Id
                FROM To_Do_Task__c
                WHERE Id = :taskId
                AND OwnerId = :UserInfo.getUserId()
                WITH SECURITY_ENFORCED
            ];
            t.Name = newName;
            t.Priority__c = priority;
            t.Category__c = category;
            t.Notes__c = notes;
            t.Recurrence__c = recurrence;

            SObjectAccessDecision decision = Security.stripInaccessible(
                AccessType.UPDATABLE, new List<To_Do_Task__c>{ t }
            );
            update decision.getRecords();
        } catch (QueryException e) {
            throw new AuraHandledException('Task not found');
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    // Persists a new manual sort order for the running user's pending tasks after a
    // drag-and-drop reorder. orderedTaskIds must be scoped to the running user's own
    // records — re-querying ownership here (rather than trusting the client-supplied
    // list) prevents one user from reordering (or discovering the existence of)
    // another user's tasks.
    @AuraEnabled
    public static void reorderTasks(List<Id> orderedTaskIds) {
        try {
            Set<Id> ownedIds = new Set<Id>();
            for (To_Do_Task__c t : [
                SELECT Id
                FROM To_Do_Task__c
                WHERE Id IN :orderedTaskIds
                AND OwnerId = :UserInfo.getUserId()
                WITH SECURITY_ENFORCED
            ]) {
                ownedIds.add(t.Id);
            }

            List<To_Do_Task__c> updates = new List<To_Do_Task__c>();
            for (Integer i = 0; i < orderedTaskIds.size(); i++) {
                if (ownedIds.contains(orderedTaskIds[i])) {
                    updates.add(new To_Do_Task__c(Id = orderedTaskIds[i], Sort_Order__c = i));
                }
            }

            SObjectAccessDecision decision = Security.stripInaccessible(AccessType.UPDATABLE, updates);
            update decision.getRecords();
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    @AuraEnabled
    public static void markAllTasksComplete() {
        try {
            List<To_Do_Task__c> pending = [
                SELECT Id, Completed__c, Recurrence__c
                FROM To_Do_Task__c
                WHERE Completed__c = false
                AND OwnerId = :UserInfo.getUserId()
                WITH SECURITY_ENFORCED
            ];

            for (To_Do_Task__c t : pending) {
                applyCompletion(t);
            }

            SObjectAccessDecision decision = Security.stripInaccessible(AccessType.UPDATABLE, pending);
            update decision.getRecords();
        } catch (QueryException e) {
            throw new AuraHandledException('Insufficient permissions to complete this action');
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    // "Clear Completed" archives rather than deletes — nothing is lost, it's just
    // hidden from the normal Completed list until restored via restoreArchivedTask.
    @AuraEnabled
    public static void clearCompletedTasks() {
        try {
            List<To_Do_Task__c> completed = [
                SELECT Id, Archived__c
                FROM To_Do_Task__c
                WHERE Status__c = 'Completed'
                AND Archived__c = false
                AND OwnerId = :UserInfo.getUserId()
                WITH SECURITY_ENFORCED
            ];

            for (To_Do_Task__c t : completed) {
                t.Archived__c = true;
            }

            SObjectAccessDecision decision = Security.stripInaccessible(AccessType.UPDATABLE, completed);
            update decision.getRecords();
        } catch (QueryException e) {
            throw new AuraHandledException('Insufficient permissions to complete this action');
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    // Brings a single archived task back into the normal Completed list.
    @AuraEnabled
    public static void restoreArchivedTask(Id taskId) {
        try {
            // Scoping the query to the running user's own records prevents one user
            // from restoring a task that belongs to someone else (IDOR protection).
            To_Do_Task__c t = [
                SELECT Id
                FROM To_Do_Task__c
                WHERE Id = :taskId
                AND OwnerId = :UserInfo.getUserId()
                WITH SECURITY_ENFORCED
            ];
            t.Archived__c = false;

            SObjectAccessDecision decision = Security.stripInaccessible(
                AccessType.UPDATABLE, new List<To_Do_Task__c>{ t }
            );
            update decision.getRecords();
        } catch (QueryException e) {
            throw new AuraHandledException('Task not found');
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    // Brings every archived task back into the normal Completed list in one action.
    @AuraEnabled
    public static void restoreAllArchivedTasks() {
        try {
            List<To_Do_Task__c> archived = [
                SELECT Id, Archived__c
                FROM To_Do_Task__c
                WHERE Status__c = 'Completed'
                AND Archived__c = true
                AND OwnerId = :UserInfo.getUserId()
                WITH SECURITY_ENFORCED
            ];

            for (To_Do_Task__c t : archived) {
                t.Archived__c = false;
            }

            SObjectAccessDecision decision = Security.stripInaccessible(AccessType.UPDATABLE, archived);
            update decision.getRecords();
        } catch (QueryException e) {
            throw new AuraHandledException('Insufficient permissions to complete this action');
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    // Checks the running user's completed recurring tasks and, for any whose scheduled
    // Next_Occurrence_Date__c has arrived, creates the next pending occurrence. Not
    // cacheable (it performs DML), so it's called imperatively before the pending list
    // loads rather than through the cacheable getPendingTasks wire.
    @AuraEnabled
    public static void materializeDueRecurrences() {
        try {
            List<To_Do_Task__c> due = [
                SELECT Id, Name, Priority__c, Category__c, Notes__c, Recurrence__c
                FROM To_Do_Task__c
                WHERE OwnerId = :UserInfo.getUserId()
                AND Status__c = 'Completed'
                AND Recurrence__c != null
                AND Recurrence__c != 'None'
                AND Next_Occurrence_Date__c != null
                AND Next_Occurrence_Date__c <= TODAY
                WITH SECURITY_ENFORCED
            ];

            if (due.isEmpty()) {
                return;
            }

            List<To_Do_Task__c> newOccurrences = new List<To_Do_Task__c>();
            List<To_Do_Task__c> originalsToClear = new List<To_Do_Task__c>();

            for (To_Do_Task__c original : due) {
                newOccurrences.add(new To_Do_Task__c(
                    Name = original.Name,
                    Completed__c = false,
                    Status__c = 'Pending',
                    Priority__c = original.Priority__c,
                    Category__c = original.Category__c,
                    Notes__c = original.Notes__c,
                    Recurrence__c = original.Recurrence__c
                ));
                // Clearing Next_Occurrence_Date__c stops this completed task from
                // spawning another occurrence the next time this method runs.
                originalsToClear.add(new To_Do_Task__c(
                    Id = original.Id,
                    Next_Occurrence_Date__c = null
                ));
            }

            SObjectAccessDecision createDecision = Security.stripInaccessible(AccessType.CREATABLE, newOccurrences);
            insert createDecision.getRecords();

            SObjectAccessDecision updateDecision = Security.stripInaccessible(AccessType.UPDATABLE, originalsToClear);
            update updateDecision.getRecords();
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }
}
