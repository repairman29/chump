//! Proc macro for Chump tools: `#[chump_tool(name = "...", description = "...", schema = r#"..."#)]` on an
//! `impl Tool for T { async fn execute(...) { ... } }` block. Expands to a full impl with name, description, input_schema, and execute.

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use proc_macro2::Literal;
use quote::quote;
use syn::{
    parse::Parser,
    parse_macro_input,
    punctuated::Punctuated,
    token::Comma,
    Expr, ImplItem, ItemImpl, Lit, MetaNameValue, Result,
};

fn parse_string_from_value(expr: &Expr) -> Result<String> {
    match expr {
        Expr::Lit(e) => match &e.lit {
            Lit::Str(lit) => Ok(lit.value()),
            _ => Err(syn::Error::new_spanned(expr, "expected string literal")),
        },
        _ => Err(syn::Error::new_spanned(expr, "expected string literal")),
    }
}

fn parse_attr_args(attr: TokenStream) -> Result<(String, String, String)> {
    let parser = Punctuated::<MetaNameValue, Comma>::parse_terminated;
    let attrs = parser.parse2(TokenStream2::from(attr))?;
    let mut name = None;
    let mut description = None;
    let mut schema = None;
    for nv in attrs {
        let key = nv.path.get_ident().map(|i| i.to_string());
        let s = parse_string_from_value(&nv.value)?;
        match key.as_deref() {
            Some("name") => name = Some(s),
            Some("description") => description = Some(s),
            Some("schema") => schema = Some(s),
            _ => return Err(syn::Error::new_spanned(nv.path, "unknown key; use name, description, schema")),
        }
    }
    let name = name.ok_or_else(|| syn::Error::new(proc_macro2::Span::call_site(), "chump_tool missing name"))?;
    let description = description.ok_or_else(|| syn::Error::new(proc_macro2::Span::call_site(), "chump_tool missing description"))?;
    let schema = schema.ok_or_else(|| syn::Error::new(proc_macro2::Span::call_site(), "chump_tool missing schema"))?;
    if serde_json::from_str::<serde_json::Value>(&schema).is_err() {
        return Err(syn::Error::new(proc_macro2::Span::call_site(), "chump_tool schema must be valid JSON"));
    }
    Ok((name, description, schema))
}

#[proc_macro_attribute]
pub fn chump_tool(attr: TokenStream, item: TokenStream) -> TokenStream {
    let (tool_name, tool_description, tool_schema) = match parse_attr_args(attr) {
        Ok(t) => t,
        Err(e) => return e.into_compile_error().into(),
    };
    let impl_block = parse_macro_input!(item as ItemImpl);
    let name_type = impl_block.self_ty.clone();
    let (trait_path, execute_item) = {
        let trait_ref = impl_block.trait_.as_ref().ok_or_else(|| {
            syn::Error::new_spanned(&impl_block, "chump_tool requires impl Tool for T")
        });
        let trait_ref = match trait_ref {
            Ok(r) => r,
            Err(e) => return e.into_compile_error().into(),
        };
        let path = &trait_ref.1;
        if !path.is_ident("Tool") {
            return syn::Error::new_spanned(path, "chump_tool requires impl Tool for T")
                .into_compile_error()
                .into();
        }
        let execute = impl_block.items.iter().find_map(|i| {
            if let ImplItem::Fn(m) = i {
                if m.sig.ident == "execute" {
                    return Some(m.clone());
                }
            }
            None
        });
        let execute = match execute {
            Some(e) => e,
            None => {
                return syn::Error::new_spanned(
                    &impl_block,
                    "chump_tool impl block must contain async fn execute",
                )
                .into_compile_error()
                .into()
            }
        };
        (path.clone(), execute)
    };

    let name_lit = Literal::string(&tool_name);
    let desc_lit = Literal::string(&tool_description);
    let schema_lit = Literal::string(&tool_schema);
    let expanded = quote! {
        #[::async_trait::async_trait]
        impl #trait_path for #name_type {
            fn name(&self) -> String {
                #name_lit.to_string()
            }

            fn description(&self) -> String {
                #desc_lit.to_string()
            }

            fn input_schema(&self) -> ::serde_json::Value {
                ::serde_json::from_str(#schema_lit).expect("tool schema is valid JSON")
            }

            #execute_item
        }
    };
    TokenStream::from(expanded)
}
