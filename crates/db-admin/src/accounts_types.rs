use crate::admin_common_derives;

admin_common_derives! {
    pub struct Account {
        pub id: String,
        pub turso_db_name: String,
        pub clerk_org_id: Option<String>,
    }
}
