/**
 * @description       :
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             :
 * @last modified on  : 03-27-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
public with sharing class TaskController {

    // Both lists page in fixed windows of this size rather than loading everything
    // at once — keeps each server round trip small no matter how many tasks exist.
    private static final Integer PAGE_SIZE = 15;

    // Wire result shape for both paginated list methods: the current page of records,
    // plus the total row count across every page (so the client can render "Page X of Y"
    // and disable Next appropriately) — one round trip instead of two.
    public class PagedTasks {
        @AuraEnabled public List<To_Do_Task__c> records;
        @AuraEnabled public Integer totalCount;

        public PagedTasks(List<To_Do_Task__c> records, Integer totalCount) {
            this.records = records;
            this.totalCount = totalCount;
        }
    }

    // Turns a 1-based page number into a safe SOQL OFFSET.
    private static Integer offsetFor(Integer pageNumber) {
        Integer safePage = (pageNumber == null || pageNumber < 1) ? 1 : pageNumber;
        return (safePage - 1) * PAGE_SIZE;
    }

    // Wraps a raw search term into a SOQL LIKE pattern. An empty/blank term produces
    // '%%', which matches every row — i.e. no filtering — so callers don't need to
    // branch on whether a search is active.
    private static String likePattern(String searchTerm) {
        return '%' + (searchTerm == null ? '' : searchTerm) + '%';
    }

    // searchTerm filters by task Name — Notes__c is a Long Text Area, and Salesforce
    // doesn't allow SOQL WHERE clauses to filter on that field type. cacheBuster is
    // never read — its only job is to give the client's @wire cache a fresh key on
    // every call. Without it, paging back to a page (or search term) the client
    // already queried earlier in the session can silently replay a stale cached
    // response after a mutation, because refreshApex only busts the cache entry for
    // the currently active parameters.
    @AuraEnabled(cacheable=true)
    public static PagedTasks getPendingTasks(String searchTerm, Integer pageNumber, Integer cacheBuster) {
        String pattern = likePattern(searchTerm);
        Integer pageOffset = offsetFor(pageNumber);

        Integer totalCount = [
            SELECT COUNT()
            FROM To_Do_Task__c
            WHERE Completed__c = false
            AND OwnerId = :UserInfo.getUserId()
            AND Name LIKE :pattern
            WITH SECURITY_ENFORCED
        ];

        List<To_Do_Task__c> records = [
            SELECT Id, Name, Completed__c, Priority__c, Category__c, Notes__c, Sort_Order__c, Recurrence__c
            FROM To_Do_Task__c
            WHERE Completed__c = false
            AND OwnerId = :UserInfo.getUserId()
            AND Name LIKE :pattern
            WITH SECURITY_ENFORCED
            ORDER BY Sort_Order__c ASC NULLS FIRST, CreatedDate DESC
            LIMIT :PAGE_SIZE
            OFFSET :pageOffset
        ];

        return new PagedTasks(records, totalCount);
    }

    @AuraEnabled(cacheable=true)
    public static PagedTasks getCompletedTasks(String filterType, String searchTerm, Integer pageNumber, Integer cacheBuster) {
        String pattern = likePattern(searchTerm);
        Integer pageOffset = offsetFor(pageNumber);

        // The Archived view shows tasks "Clear Completed" hid from the normal list —
        // it's the only view that includes Archived__c = true records.
        if (filterType == 'ARCHIVED') {
            Integer totalCount = [
                SELECT COUNT()
                FROM To_Do_Task__c
                WHERE Status__c = 'Completed'
                AND Archived__c = true
                AND OwnerId = :UserInfo.getUserId()
                AND Name LIKE :pattern
                WITH SECURITY_ENFORCED
            ];
            List<To_Do_Task__c> records = [
                SELECT Id, Name, Completed_Date__c, Priority__c, Category__c, Notes__c, Recurrence__c
                FROM To_Do_Task__c
                WHERE Status__c = 'Completed'
                AND Archived__c = true
                AND OwnerId = :UserInfo.getUserId()
                AND Name LIKE :pattern
                WITH SECURITY_ENFORCED
                ORDER BY Completed_Date__c DESC NULLS LAST
                LIMIT :PAGE_SIZE
                OFFSET :pageOffset
            ];
            return new PagedTasks(records, totalCount);
        }

        Date startDate;

        if (filterType == 'WEEK') {
            startDate = Date.today().toStartOfWeek();
        } else if (filterType == 'MONTH') {
            startDate = Date.today().toStartOfMonth();
        }

        if (startDate != null) {
            Integer totalCount = [
                SELECT COUNT()
                FROM To_Do_Task__c
                WHERE Status__c = 'Completed'
                AND Archived__c = false
                AND OwnerId = :UserInfo.getUserId()
                AND Completed_Date__c >= :startDate
                AND Name LIKE :pattern
                WITH SECURITY_ENFORCED
            ];
            List<To_Do_Task__c> records = [
                SELECT Id, Name, Completed_Date__c, Priority__c, Category__c, Notes__c, Recurrence__c
                FROM To_Do_Task__c
                WHERE Status__c = 'Completed'
                AND Archived__c = false
                AND OwnerId = :UserInfo.getUserId()
                AND Completed_Date__c >= :startDate
                AND Name LIKE :pattern
                WITH SECURITY_ENFORCED
                ORDER BY Completed_Date__c DESC NULLS LAST
                LIMIT :PAGE_SIZE
                OFFSET :pageOffset
            ];
            return new PagedTasks(records, totalCount);
        } else {
            Integer totalCount = [
                SELECT COUNT()
                FROM To_Do_Task__c
                WHERE Status__c = 'Completed'
                AND Archived__c = false
                AND OwnerId = :UserInfo.getUserId()
                AND Name LIKE :pattern
                WITH SECURITY_ENFORCED
            ];
            List<To_Do_Task__c> records = [
                SELECT Id, Name, Completed_Date__c, Priority__c, Category__c, Notes__c, Recurrence__c
                FROM To_Do_Task__c
                WHERE Status__c = 'Completed'
                AND Archived__c = false
                AND OwnerId = :UserInfo.getUserId()
                AND Name LIKE :pattern
                WITH SECURITY_ENFORCED
                ORDER BY Completed_Date__c DESC NULLS LAST
                LIMIT :PAGE_SIZE
                OFFSET :pageOffset
            ];
            return new PagedTasks(records, totalCount);
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
    //
    // startIndex offsets the assigned Sort_Order__c values so a reorder on page 2 (say)
    // doesn't overwrite page 1's ordering — only one page's worth of tasks is ever in
    // the DOM at a time, so the client passes the dragged page's own starting offset
    // (page 2 with a page size of 15 passes 15, meaning these tasks get orders 15-29).
    @AuraEnabled
    public static void reorderTasks(List<Id> orderedTaskIds, Integer startIndex) {
        try {
            Integer safeStartIndex = (startIndex == null || startIndex < 0) ? 0 : startIndex;

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
                    updates.add(new To_Do_Task__c(Id = orderedTaskIds[i], Sort_Order__c = safeStartIndex + i));
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
