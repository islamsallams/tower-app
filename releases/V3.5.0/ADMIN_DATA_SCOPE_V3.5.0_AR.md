# مراجعة نطاق بيانات Tower App V3.5.0

هذه ورقة اقتراح للمراجعة، ولا تمنح تنفيذ حذف أو استعادة. SQL263 يعرض أعداد الجداول الموجودة وعلاقاتها؛ أي جدول خارج القائمتين يبقى غير مصنف ويحتاج قرارًا، ولا يضاف للحذف تلقائيًا.

الاقتراح يحذف الحركة التشغيلية المالية، والاشتراكات وطلبات تعديلها، وبيانات تشغيل المهمات ومشاويرها وتسوياتها، وقراءة الإشعارات وطوابير الإرسال المحددة. يحتفظ بالحسابات والوحدات والعضويات والأنواع والحالات والإعدادات وتعريفات الخدمات والحسابات المالية وأصحاب الاستحقاق التاريخيين وسجل التدقيق وطلبات الانضمام وPIN وسجلات البنية.

تعريفات المهمات والخدمات تحتاج قرار إعادة فتح التسجيل بعد التصفير مع بقاء تعريفها، وإزالة بقايا العلاقات في الاتجاهين. المعاينة تعرض كل FK من القاعدة الفعلية بما فيها العلاقات الدائرية أو من محفوظ إلى مقترح حذف. لا تستخدم تعطيل القيود لتجاوز المراجعة.

الاستعادة الفعلية المقترحة تحتاج قاعدة بنفس الإصدار والبنية، معاملة ذرية، نسخة أمان قابلة للتحقق قبل الكتابة، حماية هوية الأدمن، عدم إعادة تنشيط الجلسات، وحسم طوابير الإرسال وإيقاف جدولتها أثناء العملية، واختبار فشل متعمد يثبت الرجوع الكامل. لم تُنفذ هذه الاستعادة بعد، ولا يوجد زر تنفيذ في هذا الإصدار.

## الجداول المقترح حذف بياناتها

- الجدول `tower_payment_attachments`.
- الجدول `tower_building_payments`.
- الجدول `tower_building_allocations`.
- الجدول `tower_building_charges`.
- الجدول `tower_charge_history_240`.
- الجدول `tower_charge_requests_240`.
- الجدول `tower_collection_lines`.
- الجدول `tower_collection_reports`.
- الجدول `tower_collection_batches_233`.
- الجدول `tower_fund_entries`.
- الجدول `tower_finance_advance_subscription_links`.
- الجدول `tower_finance_advance_use_subscriptions`.
- الجدول `tower_finance_advance_uses`.
- الجدول `tower_finance_applications`.
- الجدول `tower_finance_cash_movements`.
- الجدول `tower_finance_dues`.
- الجدول `tower_finance_mixed_collections`.
- الجدول `tower_finance_receipt_portions`.
- الجدول `tower_finance_receipts`.
- الجدول `tower_finance_refund_authorizations`.
- الجدول `tower_finance_refund_movements`.
- الجدول `tower_service_change_requests`.
- الجدول `tower_service_subscriptions`.
- الجدول `tower_trip_change_history`.
- الجدول `tower_trip_settlement_details`.
- الجدول `tower_trip_payments`.
- الجدول `tower_trips`.
- الجدول `tower_trip_settlements`.
- الجدول `tower_trip_notice_reads_257`.
- الجدول `tower_notifications`.
- الجدول `tower_notification_reads`.
- الجدول `tower_notice_history_259`.
- الجدول `tower_telegram_delivery_log`.
- الجدول `tower_telegram_pdf_jobs`.
- الجدول `tower_task_adjustments`.
- الجدول `tower_task_adjustment_lines`.
- الجدول `tower_task_agreements`.
- الجدول `tower_task_allocation_snapshots`.
- الجدول `tower_task_advance_refund_allocations`.
- الجدول `tower_task_credit_refunds`.
- الجدول `tower_task_credit_reversals`.
- الجدول `tower_task_donations`.
- الجدول `tower_task_donation_returns`.
- الجدول `tower_task_due_credits`.
- الجدول `tower_task_due_installments`.
- الجدول `tower_task_event_reads`.
- الجدول `tower_task_events`.
- الجدول `tower_task_expense_disbursements`.
- الجدول `tower_task_expenses`.
- الجدول `tower_task_fund_contributions`.
- الجدول `tower_task_fund_receipts`.
- الجدول `tower_task_interests`.
- الجدول `tower_task_projects`.
- الجدول `tower_task_requests_236`.
- الجدول `tower_task_workflow`.

## الجداول المقترح الاحتفاظ بها

- الجدول `tower_audit`.
- الجدول `tower_brand_assets`.
- الجدول `tower_brand_presentation_251`.
- الجدول `tower_collection_categories`.
- الجدول `tower_daily_digest_schedule`.
- الجدول `tower_login_attempts`.
- الجدول `tower_member_requests`.
- الجدول `tower_members`.
- الجدول `tower_pin_reset_requests`.
- الجدول `tower_registration_requests`.
- الجدول `tower_schema_baselines`.
- الجدول `tower_schema_migration_registry`.
- الجدول `tower_schema_migrations`.
- الجدول `tower_services`.
- الجدول `tower_service_edit_history_230`.
- الجدول `tower_sessions`.
- الجدول `tower_system_settings`.
- الجدول `tower_telegram_accounts`.
- الجدول `tower_telegram_cron_health`.
- الجدول `tower_telegram_links`.
- الجدول `tower_telegram_pdf_preferences`.
- الجدول `tower_telegram_pdf_schedule`.
- الجدول `tower_titles`.
- الجدول `tower_trip_settings`.
- الجدول `tower_ui_preferences`.
- الجدول `tower_unit_fund_visibility`.
- الجدول `tower_unit_types`.
- الجدول `tower_units`.
- الجدول `tower_users`.
- الجدول `tower_welcome_progress`.
- الجدول `tower_personal_ui_preferences_248`.
- الجدول `tower_unit_states_262`.
- الجدول `tower_trip_unit_preferences_242`.
- الجدول `tower_finance_accounts`.
- الجدول `tower_finance_service_beneficiaries`.
