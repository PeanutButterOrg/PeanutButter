use async_graphql::{EmptySubscription, Schema};

use super::{Mutation, Query};
use crate::AppState;

pub type AppSchema = Schema<Query, Mutation, EmptySubscription>;

pub fn build_schema(state: AppState) -> AppSchema {
    Schema::build(Query, Mutation, EmptySubscription)
        .data(state)
        .finish()
}
