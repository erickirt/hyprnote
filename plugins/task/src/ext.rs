use std::future::Future;

use tauri::{AppHandle, Manager, Runtime};
use tauri_plugin_store2::{ScopedStore, StorePluginExt};

use crate::{StoreKey, TaskCtx, TaskRecord, TaskState, TaskStatus};

pub trait TaskPluginExt<R: Runtime>: Manager<R> {
    fn task_store(&self) -> ScopedStore<R, StoreKey>;

    fn spawn_task<F, Fut>(&self, total_steps: u32, exec: F) -> String
    where
        F: Fn(TaskCtx<R>) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<(), crate::Error>> + Send + 'static;

    fn get_task(&self, id: String) -> Option<TaskRecord>;
    fn cancel_task(&self, id: String) -> Result<(), crate::Error>;
}

impl<R: Runtime, T: Manager<R>> TaskPluginExt<R> for T {
    fn task_store(&self) -> ScopedStore<R, StoreKey> {
        self.scoped_store(crate::PLUGIN_NAME).unwrap()
    }

    fn spawn_task<F, Fut>(&self, total_steps: u32, exec: F) -> String
    where
        F: Fn(TaskCtx<R>) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<(), crate::Error>> + Send + 'static,
    {
        let id = uuid::Uuid::new_v4().to_string();
        let ctx = TaskCtx::new(id.clone(), total_steps, self.task_store());

        let task_state: tauri::State<TaskState> = self.state();
        let app_handle: AppHandle<R> = self.app_handle().clone();

        let cancel_flag = ctx.cancelled_flag();
        task_state.register_task(id.clone(), cancel_flag);

        let initial_record = TaskRecord {
            id: id.clone(),
            status: TaskStatus::Running {
                current: 0,
                total: total_steps,
            },
            data: std::collections::HashMap::new(),
        };

        let _ = self
            .task_store()
            .set(StoreKey::Tasks(id.clone()), initial_record);

        let task_id = id.clone();
        tauri::async_runtime::spawn(async move {
            // Execute the task - the implementation is responsible for calling
            // ctx.complete() or ctx.fail() to update the final status
            let _ = exec(ctx).await;

            // Remove from active tasks
            if let Some(state) = app_handle.try_state::<TaskState>() {
                state.remove_task(&task_id);
            }
        });

        id
    }

    fn get_task(&self, id: String) -> Option<TaskRecord> {
        self.task_store().get(StoreKey::Tasks(id)).ok().flatten()
    }

    fn cancel_task(&self, id: String) -> Result<(), crate::Error> {
        let task_state: tauri::State<TaskState> = self.state();

        // Set the cancellation flag
        if task_state.cancel_task(&id) {
            // Update the task status in store
            if let Some(mut record) = self.get_task(id.clone()) {
                record.status = TaskStatus::Cancelled;
                self.task_store()
                    .set(StoreKey::Tasks(id), record)
                    .map_err(|_| crate::Error::StoreError)?;
            }
            Ok(())
        } else {
            // Task not found or already completed
            Ok(())
        }
    }
}
