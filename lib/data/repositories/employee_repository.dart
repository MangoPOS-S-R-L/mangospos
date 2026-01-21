import 'package:supabase_flutter/supabase_flutter.dart';

class Employee {
  final String id;
  final String businessId;
  final String? userId;
  final String firstName;
  final String lastName;
  final String email;
  final String phone;
  final String? nationalId;
  final String? gender;
  final String? address;
  final String status; // active | inactive | password_reset
  final DateTime? hireDate;
  final String? contractType;
  final String? department;
  final String? position;
  final String? workSchedule;
  final double? salaryBase;
  final String? payFrequency;
  final String? bankName;
  final String? bankAccount;
  final String? emergencyName;
  final String? emergencyRelation;
  final String? emergencyPhone;
  final String? pin;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final List<String> roles;

  Employee({
    required this.id,
    required this.businessId,
    this.userId,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.phone,
    this.nationalId,
    this.gender,
    this.address,
    required this.status,
    this.hireDate,
    this.contractType,
    this.department,
    this.position,
    this.workSchedule,
    this.salaryBase,
    this.payFrequency,
    this.bankName,
    this.bankAccount,
    this.emergencyName,
    this.emergencyRelation,
    this.emergencyPhone,
    this.pin,
    required this.createdAt,
    this.updatedAt,
    required this.roles,
  });

  String get fullName => '$firstName $lastName'.trim();

  String get initials {
    String two = '';
    if (firstName.isNotEmpty) two += firstName[0];
    final ln = lastName.isNotEmpty
        ? lastName
        : (fullName.split(' ').length > 1 ? fullName.split(' ')[1] : '');
    if (ln.isNotEmpty) two += ln[0];
    return two.toUpperCase();
  }

  factory Employee.fromMap(Map<String, dynamic> map) {
    double? salary;
    final rawSalary = map['salary_base'];
    if (rawSalary is num) {
      salary = rawSalary.toDouble();
    } else if (rawSalary is String) {
      salary = double.tryParse(rawSalary);
    }

    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      if (value is DateTime) return value;
      if (value is String) return DateTime.tryParse(value);
      return null;
    }

    return Employee(
      id: map['id'] as String,
      businessId: map['business_id'] as String,
      userId: map['user_id'] as String?,
      firstName: map['first_name'] as String? ?? '',
      lastName: map['last_name'] as String? ?? '',
      email: map['email'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      nationalId: map['national_id'] as String?,
      gender: map['gender'] as String?,
      address: map['address'] as String?,
      status: map['status'] as String? ?? 'active',
      hireDate: parseDate(map['hire_date']),
      contractType: map['contract_type'] as String?,
      department: map['department'] as String?,
      position: map['position'] as String?,
      workSchedule: map['work_schedule'] as String?,
      salaryBase: salary,
      payFrequency: map['pay_frequency'] as String?,
      bankName: map['bank_name'] as String?,
      bankAccount: map['bank_account'] as String?,
      emergencyName: map['emergency_name'] as String?,
      emergencyRelation: map['emergency_relation'] as String?,
      emergencyPhone: map['emergency_phone'] as String?,
      pin: map['pin'] as String?,
      createdAt: parseDate(map['created_at']) ?? DateTime.now(),
      updatedAt: parseDate(map['updated_at']),
      roles: (map['roles'] is List)
          ? List<String>.from(map['roles'])
          : const [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'business_id': businessId,
      'user_id': userId,
      'first_name': firstName,
      'last_name': lastName,
      'email': email,
      'phone': phone,
      'national_id': nationalId,
      'gender': gender,
      'address': address,
      'status': status,
      'hire_date': hireDate?.toIso8601String(),
      'contract_type': contractType,
      'department': department,
      'position': position,
      'work_schedule': workSchedule,
      'salary_base': salaryBase,
      'pay_frequency': payFrequency,
      'bank_name': bankName,
      'bank_account': bankAccount,
      'emergency_name': emergencyName,
      'emergency_relation': emergencyRelation,
      'emergency_phone': emergencyPhone,
      'pin': pin,
    };
  }
}

class EmployeeRepository {
  final SupabaseClient _client;
  EmployeeRepository(this._client);

  Future<List<Employee>> fetchEmployees({required String businessId}) async {
    final res = await _client
        .from('v_employees_summary')
        .select('*')
        .eq('business_id', businessId);

    final list = (res as List)
        .map((row) => Employee.fromMap(row as Map<String, dynamic>))
        .toList();

    return list;
  }

  Future<Employee> createEmployee({
    required String businessId,
    required String firstName,
    required String lastName,
    required String email,
    required String phone,
    String? nationalId,
    String? gender,
    String? address,
    String status = 'active',
    DateTime? hireDate,
    String? contractType,
    String? department,
    String? position,
    String? workSchedule,
    double? salaryBase,
    String? payFrequency,
    String? bankName,
    String? bankAccount,
    String? emergencyName,
    String? emergencyRelation,
    String? emergencyPhone,
    String? pin,
    String? password,
    List<String> roleIds = const [],
  }) async {
    final insert = {
      'business_id': businessId,
      'first_name': firstName,
      'last_name': lastName,
      'email': email,
      'phone': phone,
      'national_id': nationalId,
      'gender': gender,
      'address': address,
      'status': status,
      'hire_date': hireDate?.toIso8601String(),
      'contract_type': contractType,
      'department': department,
      'position': position,
      'work_schedule': workSchedule,
      'salary_base': salaryBase,
      'pay_frequency': payFrequency,
      'bank_name': bankName,
      'bank_account': bankAccount,
      'emergency_name': emergencyName,
      'emergency_relation': emergencyRelation,
      'emergency_phone': emergencyPhone,
      'pin': pin,
    };

    // Remover valores nulos
    insert.removeWhere((key, value) => value == null);

    // Si se proporciona contraseña, creamos el usuario de Auth primero
    String? createdAuthUserId;
    if (password != null && password.isNotEmpty) {
      try {
        final res = await _client.rpc(
          'create_new_user',
          params: {
            'email': email,
            'password': password,
            'user_metadata': {
              'first_name': firstName,
              'last_name': lastName,
              'business_id':
                  businessId, // << IMPORTANTE: Guardamos el ID del negocio
            },
          },
        );
        createdAuthUserId = res as String;
        // Asignamos el ID de auth creado al empleado
        insert['user_id'] = createdAuthUserId;
      } catch (e) {
        // Si falla la creación del usuario Auth, lanzamos error (o decidimos continuar sin Auth)
        throw Exception('Error al crear usuario de acceso: $e');
      }
    }

    final inserted = await _client
        .from('employees')
        .insert(insert)
        .select()
        .single();

    final employee = Employee.fromMap(inserted);

    if (roleIds.isNotEmpty) {
      await updateEmployeeRoles(employeeId: employee.id, roleIds: roleIds);
    }

    return employee;
  }

  Future<void> updateEmployee({
    required String employeeId,
    String? firstName,
    String? lastName,
    String? email,
    String? phone,
    String? nationalId,
    String? gender,
    String? address,
    String? status,
    DateTime? hireDate,
    String? contractType,
    String? department,
    String? position,
    String? workSchedule,
    double? salaryBase,
    String? payFrequency,
    String? bankName,
    String? bankAccount,
    String? emergencyName,
    String? emergencyRelation,
    String? emergencyPhone,
    String? pin,
  }) async {
    final update = <String, dynamic>{};

    if (firstName != null) update['first_name'] = firstName;
    if (lastName != null) update['last_name'] = lastName;
    if (email != null) update['email'] = email;
    if (phone != null) update['phone'] = phone;
    if (nationalId != null) update['national_id'] = nationalId;
    if (gender != null) update['gender'] = gender;
    if (address != null) update['address'] = address;
    if (status != null) update['status'] = status;
    if (hireDate != null) update['hire_date'] = hireDate.toIso8601String();
    if (contractType != null) update['contract_type'] = contractType;
    if (department != null) update['department'] = department;
    if (position != null) update['position'] = position;
    if (workSchedule != null) update['work_schedule'] = workSchedule;
    if (salaryBase != null) update['salary_base'] = salaryBase;
    if (payFrequency != null) update['pay_frequency'] = payFrequency;
    if (bankName != null) update['bank_name'] = bankName;
    if (bankAccount != null) update['bank_account'] = bankAccount;
    if (emergencyName != null) update['emergency_name'] = emergencyName;
    if (emergencyRelation != null) {
      update['emergency_relation'] = emergencyRelation;
    }
    if (emergencyPhone != null) update['emergency_phone'] = emergencyPhone;
    if (pin != null) update['pin'] = pin;

    if (update.isNotEmpty) {
      update['updated_at'] = DateTime.now().toIso8601String();
      await _client.from('employees').update(update).eq('id', employeeId);
    }
  }

  Future<void> updateEmployeeRoles({
    required String employeeId,
    required List<String> roleIds,
  }) async {
    // Eliminar roles existentes
    await _client.from('employee_roles').delete().eq('employee_id', employeeId);

    // Insertar nuevos roles
    if (roleIds.isNotEmpty) {
      final rows = roleIds
          .map((rid) => {'employee_id': employeeId, 'role_id': rid})
          .toList();
      await _client.from('employee_roles').insert(rows);
    }
  }

  Future<List<Map<String, dynamic>>> fetchRoles({
    required String businessId,
  }) async {
    final res = await _client
        .from('roles')
        .select('id, name, description, level')
        .eq('business_id', businessId)
        .order('name');

    return List<Map<String, dynamic>>.from(res as List);
  }

  Future<void> deleteEmployee({required String employeeId}) async {
    await _client.from('employees').delete().eq('id', employeeId);
  }
}
