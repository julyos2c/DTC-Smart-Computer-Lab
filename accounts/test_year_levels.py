from django.test import TestCase
from django.core.exceptions import ValidationError
from django.db import IntegrityError, transaction
from accounts.models import User
from accounts.forms import AdminUserCreateForm, AdminUserUpdateForm
from accounts.constants import DEPARTMENTS, year_level_choices_for, department_year_levels_json
from accounts.imports import parse_year_level, validate_row


class StudentYearLevelTests(TestCase):
    def data(self, year):
        return dict(first_name='Test', last_name='Student', email='student@gmail.com',
                    id_number='YEAR-TEST', role='student', department='BSCJ', year_level=str(year))

    def test_all_departments_and_client_choices_stop_at_four(self):
        for code in DEPARTMENTS:
            self.assertEqual([value for value, _ in year_level_choices_for(code)], [1,2,3,4])
            self.assertEqual([x['value'] for x in department_year_levels_json()[code]], [1,2,3,4])

    def test_create_accepts_one_and_four(self):
        for year in (1,4):
            form=AdminUserCreateForm(data=self.data(year))
            self.assertTrue(form.is_valid(),form.errors)

    def test_create_rejects_tampered_years(self):
        for year in (0,5,6,-1,'4.5','not-a-year'):
            form=AdminUserCreateForm(data=self.data(year))
            self.assertFalse(form.is_valid())
            self.assertIn('year_level',form.errors)

    def test_edit_rejects_five(self):
        user=User.objects.create(email='student@gmail.com',id_number='YEAR-TEST',role='student',department='BSCJ',year_level=4)
        form=AdminUserUpdateForm(data=dict(self.data(5),is_active=True),instance=user)
        self.assertFalse(form.is_valid())
        self.assertIn('year_level',form.errors)

    def test_model_validation_rejects_five(self):
        field=User._meta.get_field('year_level')
        with self.assertRaises(ValidationError):field.clean(5,User())
        self.assertEqual(field.clean(4,User()),4)

    def test_database_blocks_bypassing_forms(self):
        user=User.objects.create(email=None,role='student',year_level=4)
        for year in (0,5,99):
            with self.assertRaises(IntegrityError), transaction.atomic():
                User.objects.filter(pk=user.pk).update(year_level=year)
        user.refresh_from_db()
        self.assertEqual(user.year_level,4)

    def test_import_valid_year_labels_and_excel_numbers(self):
        for value in (4,'4','4th Year','Year 4',4.0,'4.0'):
            self.assertEqual(parse_year_level(value),4)
            self.assertFalse(validate_row(dict(self.data(4),year_level=value),'BSCJ'))

    def test_import_rejects_five_fractions_and_zero(self):
        for value in (5,'5th Year',4.5,'4.5',0,'0'):
            self.assertTrue(any('Year Level' in error for error in validate_row(dict(self.data(4),year_level=value),'BSCJ')))

    def test_browser_uses_a_four_year_select(self):
        field=AdminUserCreateForm().fields['year_level']
        html=field.widget.render('year_level',None)
        self.assertIn('<select',html)
        self.assertIn('value="4"',html)
        self.assertNotIn('value="5"',html)

    def test_migration_reports_invalid_existing_values(self):
        from importlib import import_module
        from unittest.mock import MagicMock
        check=import_module('accounts.migrations.0024_student_year_level_limit').check_existing_year_levels
        apps=MagicMock(); editor=MagicMock()
        apps.get_model.return_value.objects.using.return_value.filter.return_value.exclude.return_value.values_list.return_value.__getitem__.return_value=[(7,5)]
        with self.assertRaisesRegex(RuntimeError,'7: 5'):check(apps,editor)
